const Stripe = require('stripe');
const stripe = Stripe(process.env.STRIPE_SECRET_KEY);
const SUPABASE_URL = 'https://arztmxqslyfcuzlnlatb.supabase.co';

module.exports.config = { api: { bodyParser: false } };

function buffer(readable) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    readable.on('data', (chunk) => chunks.push(chunk));
    readable.on('end', () => resolve(Buffer.concat(chunks)));
    readable.on('error', reject);
  });
}

async function sbPatch(path, body) {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    method: 'PATCH',
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', Prefer: 'return=minimal' },
    body: JSON.stringify(body),
  });
}

module.exports = async (req, res) => {
  const sig = req.headers['stripe-signature'];
  let event;
  try {
    const buf = await buffer(req);
    event = stripe.webhooks.constructEvent(buf, sig, process.env.STRIPE_WEBHOOK_SECRET);
  } catch (err) {
    console.error('assinatura invalida', err.message);
    return res.status(400).send(`Webhook Error: ${err.message}`);
  }

  try {
    if (event.type === 'checkout.session.completed') {
      const session = event.data.object;
      const usuarioId = session.client_reference_id || (session.metadata && session.metadata.usuario_id);
      if (usuarioId) {
        await sbPatch(`usuarios?id=eq.${usuarioId}`, {
          plano_atual: 'pro',
          stripe_customer_id: session.customer,
          stripe_subscription_id: session.subscription,
        });
      }
    }

    if (event.type === 'customer.subscription.updated' || event.type === 'customer.subscription.deleted') {
      const sub = event.data.object;
      const usuarioId = sub.metadata && sub.metadata.usuario_id;
      const ativo = sub.status === 'active' || sub.status === 'trialing';
      const patch = {
        plano_atual: ativo ? 'pro' : 'gratis',
        assinatura_expira_em: sub.current_period_end ? new Date(sub.current_period_end * 1000).toISOString() : null,
      };
      if (usuarioId) {
        await sbPatch(`usuarios?id=eq.${usuarioId}`, patch);
      } else if (sub.customer) {
        await sbPatch(`usuarios?stripe_customer_id=eq.${sub.customer}`, patch);
      }
    }
  } catch (e) {
    console.error('erro processando webhook', e);
  }

  res.status(200).json({ received: true });
};
