const Stripe = require('stripe');
const stripe = Stripe(process.env.STRIPE_SECRET_KEY);
const SUPABASE_URL = 'https://arztmxqslyfcuzlnlatb.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFyenRteHFzbHlmY3V6bG5sYXRiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQzMDI4ODIsImV4cCI6MjA5OTg3ODg4Mn0.wNfWCPY-ITh1wXdoWbWg5x9wQ7bVjXyJskKKfa1lMzw';

module.exports = async (req, res) => {
  if (req.method !== 'POST') return res.status(405).json({ error: 'method not allowed' });
  try {
    const { accessToken, periodo, desconto } = req.body || {};
    if (!accessToken) return res.status(401).json({ error: 'sem token' });

    const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${accessToken}` },
    });
    if (!userRes.ok) return res.status(401).json({ error: 'token invalido' });
    const user = await userRes.json();

    const precos = {
      mensal: { unit_amount: 3600, interval: 'month', nome: 'Easyfarm Pro - Mensal' },
      anual: { unit_amount: 29700, interval: 'year', nome: 'Easyfarm Pro - Anual' },
    };
    const p = precos[periodo] || precos.mensal;
    const origin = req.headers.origin || 'https://easyfarm-nine.vercel.app';

    let discounts;
    if (desconto === 'gift30' && periodo === 'anual') {
      const coupon = await stripe.coupons.create({
        percent_off: 30,
        duration: 'once',
        name: 'CultivAI Gift Pass - 30% no primeiro ano',
      });
      discounts = [{ coupon: coupon.id }];
    }

    const session = await stripe.checkout.sessions.create({
      mode: 'subscription',
      customer_email: user.email,
      client_reference_id: user.id,
      line_items: [
        {
          price_data: {
            currency: 'brl',
            product_data: { name: p.nome },
            unit_amount: p.unit_amount,
            recurring: { interval: p.interval },
          },
          quantity: 1,
        },
      ],
      ...(discounts ? { discounts } : {}),
      success_url: `${origin}/?assinatura=sucesso`,
      cancel_url: `${origin}/?assinatura=cancelado`,
      metadata: { usuario_id: user.id },
      subscription_data: { metadata: { usuario_id: user.id } },
    });

    res.status(200).json({ url: session.url });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: 'erro ao criar checkout' });
  }
};
