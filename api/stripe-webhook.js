const Stripe = require('stripe');
const stripe = Stripe(process.env.STRIPE_SECRET_KEY);
const SUPABASE_URL = 'https://arztmxqslyfcuzlnlatb.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFyenRteHFzbHlmY3V6bG5sYXRiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQzMDI4ODIsImV4cCI6MjA5OTg3ODg4Mn0.wNfWCPY-ITh1wXdoWbWg5x9wQ7bVjXyJskKKfa1lMzw';

module.exports.config = { api: { bodyParser: false } };

function buffer(readable) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    readable.on('data', (chunk) => chunks.push(chunk));
    readable.on('end', () => resolve(Buffer.concat(chunks)));
    readable.on('error', reject);
  });
}

async function rpc(nome, args) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${nome}`, {
    method: 'POST',
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(args),
  });
  if (!res.ok) {
    const texto = await res.text();
    throw new Error(`RPC ${nome} falhou (${res.status}): ${texto}`);
  }
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
        await rpc('rpc_atualizar_assinatura', {
          p_usuario_id: usuarioId,
          p_customer_id: session.customer,
          p_subscription_id: session.subscription,
          p_plano: 'pro',
          p_expira_em: null,
        });
      }
    }

    if (event.type === 'customer.subscription.updated' || event.type === 'customer.subscription.deleted') {
      const sub = event.data.object;
      const usuarioId = sub.metadata && sub.metadata.usuario_id;
      const ativo = sub.status === 'active' || sub.status === 'trialing';
      const expiraEm = sub.current_period_end ? new Date(sub.current_period_end * 1000).toISOString() : null;
      if (usuarioId) {
        await rpc('rpc_atualizar_assinatura', {
          p_usuario_id: usuarioId,
          p_customer_id: sub.customer,
          p_subscription_id: sub.id,
          p_plano: ativo ? 'pro' : 'gratis',
          p_expira_em: expiraEm,
        });
      } else if (sub.customer) {
        await rpc('rpc_atualizar_assinatura_por_customer', {
          p_customer_id: sub.customer,
          p_plano: ativo ? 'pro' : 'gratis',
          p_expira_em: expiraEm,
        });
      }
    }
  } catch (e) {
    console.error('erro processando webhook', e);
  }

  res.status(200).json({ received: true });
};
