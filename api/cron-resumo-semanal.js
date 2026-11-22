// Resumo semanal da Easy: toda segunda de manhã, um push curto com o que importa na lavoura.
// Prioridade da mensagem: custo acima do previsto > contas pra pagar > resumo de entrou/saiu > lembretes atrasados > plano parado.
const webpush = require('web-push');

const SUPABASE_URL = 'https://arztmxqslyfcuzlnlatb.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFyenRteHFzbHlmY3V6bG5sYXRiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQzMDI4ODIsImV4cCI6MjA5OTg3ODg4Mn0.wNfWCPY-ITh1wXdoWbWg5x9wQ7bVjXyJskKKfa1lMzw';
const VAPID_PUBLIC = 'BL51_8NucANGFtw5hELloqOvV4J83JW1U9sdAF4CPsgL1clGCXsUtixHL-8SgL7zPXVqbpK3wID0SmY0YCy3ks4';
const VAPID_PRIVATE = 'JZWmfe0E8LNMdPxNdU0HgzRrzRV8-Y8TClX08dcl-pw';

webpush.setVapidDetails('mailto:pedrobruder11@gmail.com', VAPID_PUBLIC, VAPID_PRIVATE);

async function rpc(nome, body = {}) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${nome}`, {
    method: 'POST',
    headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`RPC ${nome} -> ${res.status} ${await res.text()}`);
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}

const reais = (v) => 'R$ ' + Math.round(Number(v) || 0).toLocaleString('pt-BR');

function montarMensagem(row) {
  const planos = row.planos || [];
  const progresso = row.progresso || [];
  const sims = row.sims || [];
  const gastosC = {};
  (row.gastos_cultura || []).forEach((g) => { if (g.cultura) gastosC[g.cultura] = Number(g.total) || 0; });
  const vendasC = {};
  (row.vendas_cultura || []).forEach((v) => { if (v.cultura) vendasC[v.cultura] = Number(v.total) || 0; });

  // 1) Custo real acima do previsto em alguma cultura no chão
  for (const p of planos) {
    const sim = sims.find((s) => s.cultura === p.cultura);
    if (!sim || !(Number(sim.custo) > 0)) continue;
    const feitos = progresso.filter((x) => x.cultura === p.cultura && x.feito).length;
    const pctPlano = Math.min(100, Math.round((feitos / 10) * 100));
    const pctGasto = Math.round(((gastosC[p.cultura] || 0) / Number(sim.custo)) * 100);
    if (pctGasto > pctPlano + 15 && pctGasto >= 25) {
      return `${p.cultura}: com ${pctPlano}% do plano feito, você já gastou ${pctGasto}% do custo previsto. Vale olhar onde o dinheiro está indo.`;
    }
  }
  // 2) Contas pra pagar nos próximos 7 dias
  if (Number(row.a_pagar_7d) > 0) {
    const extra = Number(row.a_receber_7d) > 0 ? ` e ${reais(row.a_receber_7d)} pra receber` : '';
    return `Esta semana vencem ${reais(row.a_pagar_7d)} em contas${extra}. Confira no Financeiro.`;
  }
  // 3) Resumo da semana passada
  if (Number(row.gastos_7d) > 0 || Number(row.vendas_7d) > 0) {
    const saldo = Number(row.vendas_7d) - Number(row.gastos_7d);
    return `Semana passada: entrou ${reais(row.vendas_7d)}, saiu ${reais(row.gastos_7d)}. ${saldo >= 0 ? 'Sobrou' : 'Faltou'} ${reais(Math.abs(saldo))}.`;
  }
  // 4) Lembretes atrasados
  if (Number(row.lembretes_atrasados) > 0) {
    const n = Number(row.lembretes_atrasados);
    return `Você tem ${n} ${n === 1 ? 'lembrete atrasado' : 'lembretes atrasados'} no calendário. Dá uma olhada.`;
  }
  // 5) Plano no chão sem lançamento nenhum: convida a lançar
  if (planos.length > 0) {
    const p = planos[0];
    if (!gastosC[p.cultura] && !vendasC[p.cultura]) {
      return `Como foi a semana no ${p.cultura.toLowerCase()}? Lance o que gastou ou vendeu falando com a Easy, leva 10 segundos.`;
    }
    return `Nova semana no ${p.cultura.toLowerCase()}. Veja o próximo passo do plano e o clima dos próximos dias.`;
  }
  return null;
}

module.exports = async (req, res) => {
  const authHeader = req.headers['authorization'];
  if (!process.env.CRON_SECRET || authHeader !== `Bearer ${process.env.CRON_SECRET}`) {
    return res.status(401).json({ error: 'unauthorized' });
  }
  try {
    const rows = (await rpc('rpc_resumo_semanal_dados')) || [];
    let enviados = 0;
    const vistos = new Set();
    for (const row of rows) {
      const corpo = montarMensagem(row);
      if (!corpo) continue;
      const payload = JSON.stringify({ title: 'Easy · resumo da semana', body: corpo, url: '/' });
      try {
        await webpush.sendNotification({ endpoint: row.endpoint, keys: { p256dh: row.p256dh, auth: row.auth } }, payload);
        enviados++;
        vistos.add(row.usuario_id);
      } catch (e) {
        if (e.statusCode === 404 || e.statusCode === 410) {
          try { await rpc('rpc_remover_push_subscription_por_endpoint', { p_endpoint: row.endpoint }); } catch (_) {}
        }
      }
    }
    res.status(200).json({ ok: true, usuarios: vistos.size, pushes: enviados, candidatos: rows.length });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: String(e) });
  }
};
