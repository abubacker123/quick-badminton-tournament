require('dotenv').config();
const express = require('express');
const path = require('path');
const crypto = require('crypto');
const Razorpay = require('razorpay');
const { createClient } = require('@supabase/supabase-js');

const app = express();
app.use(express.json({ verify: (req, res, buf) => { req.rawBody = buf; } }));
app.use(express.static(path.join(__dirname, 'public')));

const env = (name) => process.env[name] || '';
const supabaseReady = !!(env('SUPABASE_URL') && env('SUPABASE_SERVICE_ROLE_KEY'));
const supabase = supabaseReady ? createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } }) : null;
const razorpayReady = !!(env('RAZORPAY_KEY_ID') && env('RAZORPAY_KEY_SECRET'));
const razorpay = razorpayReady ? new Razorpay({ key_id: env('RAZORPAY_KEY_ID'), key_secret: env('RAZORPAY_KEY_SECRET') }) : null;

// Player portal lookup. Player ID + registered phone are checked server-side; private data is never queried from the browser.
const playerLoginAttempts = new Map();
app.post('/api/player-portal/login', async (req, res) => {
  const ip = req.ip || req.socket.remoteAddress || 'unknown';
  const now = Date.now();
  const recent = (playerLoginAttempts.get(ip) || []).filter(ts => now - ts < 15 * 60 * 1000);
  if (recent.length >= 6) return res.status(429).json({ error: 'Too many attempts. Please wait 15 minutes and try again.' });
  recent.push(now); playerLoginAttempts.set(ip, recent);
  try {
    if (!supabaseReady) return res.status(503).json({ error: 'Player portal is temporarily unavailable. Please try again later.' });
    const playerId = String(req.body?.playerId || '').trim();
    const phone = String(req.body?.phone || '').replace(/[^0-9]/g, '');
    if (!/^[A-Za-z0-9]+_[0-9]+$/.test(playerId) || phone.length < 8 || phone.length > 15) {
      return res.status(400).json({ error: 'Enter a valid Player ID and registered mobile number.' });
    }
    const { data: player, error: playerError } = await supabase.from('players')
      .select('id,name,singles_points,doubles_points,singles_wins,singles_losses,doubles_wins,doubles_losses,created_at')
      .ilike('id', playerId).eq('phone', phone).maybeSingle();
    if (playerError) throw playerError;
    if (!player) return res.status(401).json({ error: 'Player ID or mobile number did not match our records.' });

    const [matchesResult, entriesResult, paymentsResult] = await Promise.all([
      supabase.from('matches').select('id,match_type,winner_player_id,winner_player2_id,loser_player_id,loser_player2_id,tournament_id,played_at')
        .or(`winner_player_id.eq.${playerId},winner_player2_id.eq.${playerId},loser_player_id.eq.${playerId},loser_player2_id.eq.${playerId}`).order('played_at', { ascending: false }).limit(50),
      supabase.from('tournament_entries').select('id,tournament_id,entry_count,status,created_at').eq('player_id', playerId).order('created_at', { ascending: false }).limit(50),
      supabase.from('payments').select('id,tournament_type,amount_paise,currency,payment_mode,status,paid_at,created_at').eq('player_id', playerId).order('created_at', { ascending: false }).limit(50)
    ]);
    if (matchesResult.error) throw matchesResult.error;
    if (entriesResult.error) throw entriesResult.error;
    if (paymentsResult.error) throw paymentsResult.error;
    const tournamentIds = [...new Set((entriesResult.data || []).map(x => x.tournament_id).filter(Boolean))];
    let tournaments = [];
    if (tournamentIds.length) {
      const { data, error } = await supabase.from('tournaments').select('id,name,tournament_type,starts_at').in('id', tournamentIds);
      if (error) throw error;
      tournaments = data || [];
    }
    res.set('Cache-Control', 'no-store');
    res.json({ player, matches: matchesResult.data || [], entries: entriesResult.data || [], payments: paymentsResult.data || [], tournaments });
  } catch (e) {
    console.error('player-portal-login:', e.message);
    res.status(500).json({ error: 'We could not load your player profile. Please try again.' });
  }
});

app.get('/api/config', (req, res) => res.json({
  supabaseUrl: env('SUPABASE_URL'),
  supabaseAnonKey: env('SUPABASE_ANON_KEY'),
  razorpayKeyId: env('RAZORPAY_KEY_ID'),
  connected: supabaseReady,
  paymentsEnabled: razorpayReady
}));

app.post('/api/create-order', async (req, res) => {
  try {
    if (!supabaseReady || !razorpayReady) return res.status(503).json({ error: 'Payment setup is incomplete. Configure Supabase and Razorpay keys first.' });
    const { playerId, tournamentType, amount } = req.body || {};
    const fee = Number(amount);
    if (!playerId || !['singles', 'doubles'].includes(tournamentType) || !Number.isInteger(fee) || fee < (tournamentType === 'singles' ? 10000 : 20000)) {
      return res.status(400).json({ error: 'Invalid player, tournament type or fee. Amount must be in paise.' });
    }
    const { data: player, error: playerError } = await supabase.from('players').select('id').eq('id', playerId).maybeSingle();
    if (playerError || !player) return res.status(404).json({ error: 'Player not found.' });
    const order = await razorpay.orders.create({ amount: fee, currency: 'INR', receipt: `qbt_${Date.now()}`, notes: { player_id: playerId, tournament_type: tournamentType } });
    const { error: dbError } = await supabase.from('payments').insert({ player_id: playerId, amount_paise: fee, currency: 'INR', payment_mode: 'razorpay', status: 'created', tournament_type: tournamentType, gateway_order_id: order.id });
    if (dbError) throw dbError;
    res.json({ orderId: order.id, amount: order.amount, currency: order.currency, keyId: env('RAZORPAY_KEY_ID') });
  } catch (e) { console.error('create-order:', e); res.status(500).json({ error: 'Could not create payment order.' }); }
});

app.post('/api/verify-payment', async (req, res) => {
  try {
    if (!supabaseReady || !razorpayReady) return res.status(503).json({ error: 'Payment setup is incomplete.' });
    const { razorpay_order_id, razorpay_payment_id, razorpay_signature } = req.body || {};
    const expected = crypto.createHmac('sha256', env('RAZORPAY_KEY_SECRET')).update(`${razorpay_order_id}|${razorpay_payment_id}`).digest('hex');
    const a = Buffer.from(expected); const b = Buffer.from(razorpay_signature || '');
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return res.status(400).json({ error: 'Payment signature verification failed.' });
    const { error } = await supabase.from('payments').update({ status: 'paid', gateway_payment_id: razorpay_payment_id, paid_at: new Date().toISOString() }).eq('gateway_order_id', razorpay_order_id);
    if (error) throw error;
    res.json({ verified: true });
  } catch (e) { console.error('verify-payment:', e); res.status(500).json({ error: 'Could not verify payment.' }); }
});

// Razorpay webhook: configure this URL in the Razorpay dashboard.
app.post('/api/razorpay-webhook', async (req, res) => {
  try {
    const signature = req.headers['x-razorpay-signature'] || '';
    const expected = crypto.createHmac('sha256', env('RAZORPAY_WEBHOOK_SECRET')).update(req.rawBody || Buffer.from('')).digest('hex');
    const a = Buffer.from(expected); const b = Buffer.from(signature);
    if (!env('RAZORPAY_WEBHOOK_SECRET') || a.length !== b.length || !crypto.timingSafeEqual(a, b)) return res.status(400).send('Invalid signature');
    const event = req.body;
    if (event.event === 'payment.captured') {
      const p = event.payload?.payment?.entity;
      if (p?.order_id) await supabase.from('payments').update({ status: 'paid', gateway_payment_id: p.id, paid_at: new Date().toISOString() }).eq('gateway_order_id', p.order_id);
    }
    if (event.event === 'payment.failed') {
      const p = event.payload?.payment?.entity;
      if (p?.order_id) await supabase.from('payments').update({ status: 'failed', gateway_payment_id: p.id }).eq('gateway_order_id', p.order_id);
    }
    res.json({ received: true });
  } catch (e) { console.error('webhook:', e); res.status(500).send('Webhook processing failed'); }
});

app.get('*', (req, res) => res.sendFile(path.join(__dirname, 'public', 'index.html')));
const port = Number(env('PORT') || 3000);
app.listen(port, () => console.log(`Quick Badminton Tournament running at http://localhost:${port}`));
