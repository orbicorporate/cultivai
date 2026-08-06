const webpush = require('web-push');

const SUPABASE_URL = 'https://arztmxqslyfcuzlnlatb.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFyenRteHFzbHlmY3V6bG5sYXRiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQzMDI4ODIsImV4cCI6MjA5OTg3ODg4Mn0.wNfWCPY-ITh1wXdoWbWg5x9wQ7bVjXyJskKKfa1lMzw';
const VAPID_PUBLIC = 'BL51_8NucANGFtw5hELloqOvV4J83JW1U9sdAF4CPsgL1clGCXsUtixHL-8SgL7zPXVqbpK3wID0SmY0YCy3ks4';
const VAPID_PRIVATE = 'JZWmfe0E8LNMdPxNdU0HgzRrzRV8-Y8TClX08dcl-pw';

webpush.setVapidDetails('mailto:pedrobruder11@gmail.com', VAPID_PUBLIC, VAPID_PRIVATE);

async function rpc(nome, body = {}) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${nome}`, {
    method: 'POST',
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`RPC ${nome} -> ${res.status} ${await res.text()}`);
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}

module.exports = async (req, res) => {
  const authHeader = req.headers['authorization'];
  if (!process.env.CRON_SECRET || authHeader !== `Bearer ${process.env.CRON_SECRET}`) {
    return res.status(401).json({ error: 'unauthorized' });
  }

  try {
    const avisos = (await rpc('rpc_avisos_pendentes')) || [];

    let enviados = 0;
    const usuariosVistos = new Set();
    for (const row of avisos) {
      usuariosVistos.add(row.usuario_id);
      const n = row.contagem;
      const payload = JSON.stringify({
        title: 'Easyfarm',
        body: `Você tem ${n} aviso${n > 1 ? 's' : ''} pendente${n > 1 ? 's' : ''} no calendário`,
        url: '/',
      });
      try {
        await webpush.sendNotification({ endpoint: row.endpoint, keys: { p256dh: row.p256dh, auth: row.auth } }, payload);
        enviados++;
      } catch (e) {
        if (e.statusCode === 404 || e.statusCode === 410) {
          // precisa do id da subscription, nao so endpoint - busca via select simples usando anon (RLS bloqueia leitura de outros usuarios,
          // entao usamos uma RPC dedicada que aceita o endpoint diretamente)
          try {
            await rpc('rpc_remover_push_subscription_por_endpoint', { p_endpoint: row.endpoint });
          } catch (_) {}
        }
      }
    }

    await rpc('rpc_marcar_lembretes_notificados');

    // Gift Pass expirados: avisa a pessoa que o presente de 7 dias acabou
    const giftsExpirados = (await rpc('rpc_gift_passes_expirados_pendentes')) || [];
    let giftsEnviados = 0;
    for (const row of giftsExpirados) {
      const payload = JSON.stringify({
        title: 'CultivAI Gift Pass',
        body: 'Seu presente de 7 dias chegou ao fim. Assine o Pro agora com 30% de desconto no anual 🌱',
        url: '/?giftFim=1',
      });
      try {
        await webpush.sendNotification({ endpoint: row.endpoint, keys: { p256dh: row.p256dh, auth: row.auth } }, payload);
        giftsEnviados++;
      } catch (e) {
        if (e.statusCode === 404 || e.statusCode === 410) {
          try {
            await rpc('rpc_remover_push_subscription_por_endpoint', { p_endpoint: row.endpoint });
          } catch (_) {}
        }
      }
    }
    await rpc('rpc_marcar_gift_passes_notificados');

    res.status(200).json({ ok: true, usuarios_avisados: usuariosVistos.size, pushes_enviados: enviados, gifts_enviados: giftsEnviados });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: String(e) });
  }
};
