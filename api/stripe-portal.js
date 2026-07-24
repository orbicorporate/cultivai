const Stripe = require('stripe');
const stripe = Stripe(process.env.STRIPE_SECRET_KEY);
const SUPABASE_URL = 'https://arztmxqslyfcuzlnlatb.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFyenRteHFzbHlmY3V6bG5sYXRiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQzMDI4ODIsImV4cCI6MjA5OTg3ODg4Mn0.wNfWCPY-ITh1wXdoWbWg5x9wQ7bVjXyJskKKfa1lMzw';

module.exports = async (req, res) => {
  if (req.method !== 'POST') return res.status(405).json({ error: 'method not allowed' });
  try {
    const { accessToken } = req.body || {};
    if (!accessToken) return res.status(401).json({ error: 'sem token' });

    const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${accessToken}` },
    });
    if (!userRes.ok) return res.status(401).json({ error: 'token invalido' });
    const user = await userRes.json();

    const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
    const r = await fetch(`${SUPABASE_URL}/rest/v1/usuarios?id=eq.${user.id}&select=stripe_customer_id`, {
      headers: { apikey: key, Authorization: `Bearer ${key}` },
    });
    const rows = await r.json();
    const customerId = rows[0] && rows[0].stripe_customer_id;
    if (!customerId) return res.status(400).json({ error: 'sem assinatura ativa' });

    const origin = req.headers.origin || 'https://easyfarm-nine.vercel.app';
    const portal = await stripe.billingPortal.sessions.create({
      customer: customerId,
      return_url: origin,
    });
    res.status(200).json({ url: portal.url });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: 'erro ao abrir portal' });
  }
};
