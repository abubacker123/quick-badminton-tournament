# Publish Quick Badminton Tournament (Render)

This is a Node.js + Express app. Deploy it as a **Web Service**, not as a static site.

## Before publishing

- Rotate the Supabase service-role/secret key because it was included in an earlier shared ZIP. Add only the replacement to Render's environment settings.
- Keep `.env` private. It is deliberately not included in this deployment package.
- Razorpay is optional for the first public test. Leave all three Razorpay environment variables unset until you configure Razorpay Test Mode. Payments will remain disabled.

## Deploy

1. Create a private GitHub repository and upload the contents of this folder (the `package.json`, `server.js`, `public/`, `sql/`, and `render.yaml` should be at repository root).
2. In Render, choose **New → Blueprint** and connect that GitHub repository. Render will read `render.yaml` and create the web service.
3. In the service's **Environment** settings, add:
   - `SUPABASE_URL` = `https://YOUR_PROJECT.supabase.co` (base project URL, no `/rest/v1/`)
   - `SUPABASE_ANON_KEY` = your publishable/anon key
   - `SUPABASE_SERVICE_ROLE_KEY` = newly rotated server-only secret key
4. Save and deploy. Wait for the deploy to finish and for `/health` to report `{"status":"ok"}`.
5. Open the `onrender.com` URL shown in the Render service. That is the public website link.

## Payments

Do not enable real payments until Razorpay is configured and tested. For Razorpay Test Mode, add `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`, and `RAZORPAY_WEBHOOK_SECRET` as Render environment variables. Configure the webhook URL as `https://YOUR-RENDER-URL/api/razorpay-webhook`.

## Important

- Render's free web service may spin down when idle and take a little time to wake up.
- This project README notes that public registration currently does not bind a registration to a specific tournament record, and the public form does not collect doubles partners. Validate these workflows before taking real registrations.
- The player portal uses Player ID + phone as a basic login, not strong identity verification. Add OTP and stronger persistent rate limiting before broad public launch.
- Never commit `.env`, service-role keys, or Razorpay secrets to GitHub.
