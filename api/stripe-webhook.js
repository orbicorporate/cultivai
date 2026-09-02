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
  try { return await res.json(); } catch (e) { return null; }
}

// Descobre o usuario_id a partir da assinatura/customer do Stripe (metadata gravada no checkout).
async function usuarioDaInvoice(invoice) {
  if (invoice.subscription_details && invoice.subscription_details.metadata && invoice.subscription_details.metadata.usuario_id) {
    return invoice.subscription_details.metadata.usuario_id;
  }
  const subId = typeof invoice.subscription === 'string' ? invoice.subscription : (invoice.subscription && invoice.subscription.id);
  if (subId) {
    try {
      const sub = await stripe.subscriptions.retrieve(subId);
      if (sub.metadata && sub.metadata.usuario_id) return sub.metadata.usuario_id;
    } catch (e) {}
  }
  return null;
}

// Valor líquido real: bruto menos taxa do Stripe (balance_transaction do charge).
async function taxaStripeDaInvoice(invoice) {
  try {
    let chargeId = typeof invoice.charge === 'string' ? invoice.charge : (invoice.charge && invoice.charge.id);
    if (!chargeId && invoice.payment_intent) {
      const piId = typeof invoice.payment_intent === 'string' ? invoice.payment_intent : invoice.payment_intent.id;
      const pi = await stripe.paymentIntents.retrieve(piId, { expand: ['latest_charge'] });
      chargeId = pi.latest_charge && (typeof pi.latest_charge === 'string' ? pi.latest_charge : pi.latest_charge.id);
    }
    if (!chargeId) return 0;
    const charge = await stripe.charges.retrieve(chargeId, { expand: ['balance_transaction'] });
    const bt = charge.balance_transaction;
    if (bt && typeof bt === 'object' && typeof bt.fee === 'number') return bt.fee / 100;
  } catch (e) {
    console.error('nao consegui obter taxa stripe', e.message);
  }
  return 0;
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
      // API novas versoes movem current_period_end para dentro de items.data[]; mantem fallback pro formato antigo
      const periodoFim = sub.current_period_end || (sub.items && sub.items.data && sub.items.data[0] && sub.items.data[0].current_period_end);
      const expiraEm = periodoFim ? new Date(periodoFim * 1000).toISOString() : null;
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

    // --- Afiliados: comissão sobre cada fatura paga (30% do líquido, janela de meses definida no banco) ---
    if (event.type === 'invoice.paid' || event.type === 'invoice.payment_succeeded') {
      const invoice = event.data.object;
      if (invoice.amount_paid > 0 && process.env.AFILIADO_WEBHOOK_SEGREDO) {
        const usuarioId = await usuarioDaInvoice(invoice);
        if (usuarioId) {
          const taxa = await taxaStripeDaInvoice(invoice);
          const pagoEm = invoice.status_transitions && invoice.status_transitions.paid_at
            ? new Date(invoice.status_transitions.paid_at * 1000).toISOString()
            : new Date().toISOString();
          const r = await rpc('rpc_registrar_comissao', {
            p_segredo: process.env.AFILIADO_WEBHOOK_SEGREDO,
            p_usuario_id: usuarioId,
            p_customer_id: typeof invoice.customer === 'string' ? invoice.customer : (invoice.customer && invoice.customer.id),
            p_invoice_id: invoice.id,
            p_valor_bruto: invoice.amount_paid / 100,
            p_taxa_stripe: taxa,
            p_pago_em: pagoEm,
          });
          console.log('comissao', JSON.stringify(r));
        }
      }
    }

    // Reembolso ou chargeback: estorna a comissão da fatura correspondente
    if (event.type === 'charge.refunded' || event.type === 'charge.dispute.created') {
      const obj = event.data.object;
      const charge = event.type === 'charge.refunded' ? obj : null;
      let invoiceId = charge && (typeof charge.invoice === 'string' ? charge.invoice : (charge.invoice && charge.invoice.id));
      if (!invoiceId && obj.charge) {
        try {
          const ch = await stripe.charges.retrieve(typeof obj.charge === 'string' ? obj.charge : obj.charge.id);
          invoiceId = typeof ch.invoice === 'string' ? ch.invoice : (ch.invoice && ch.invoice.id);
        } catch (e) {}
      }
      if (invoiceId && process.env.AFILIADO_WEBHOOK_SEGREDO) {
        await rpc('rpc_estornar_comissao', { p_segredo: process.env.AFILIADO_WEBHOOK_SEGREDO, p_invoice_id: invoiceId });
      }
    }
  } catch (e) {
    console.error('erro processando webhook', e);
  }

  res.status(200).json({ received: true });
};
