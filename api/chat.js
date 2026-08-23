const SUPABASE_URL = 'https://arztmxqslyfcuzlnlatb.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFyenRteHFzbHlmY3V6bG5sYXRiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQzMDI4ODIsImV4cCI6MjA5OTg3ODg4Mn0.wNfWCPY-ITh1wXdoWbWg5x9wQ7bVjXyJskKKfa1lMzw';

// Busca um resumo compacto do que está rolando no perfil do produtor (culturas, progresso,
// financeiro, simulações) pra a Easy responder com contexto real. Usa o accessToken do próprio
// usuário, então RLS filtra os dados automaticamente. Falha silenciosa: se algo der errado,
// a conversa continua normalmente sem o contexto extra.
async function montarContextoUsuario(accessToken) {
  const headers = {
    apikey: SUPABASE_ANON_KEY,
    Authorization: `Bearer ${accessToken}`,
  };

  async function buscar(caminho) {
    try {
      const r = await fetch(`${SUPABASE_URL}/rest/v1/${caminho}`, { headers });
      if (!r.ok) return [];
      const json = await r.json();
      return Array.isArray(json) ? json : [];
    } catch (e) {
      return [];
    }
  }

  try {
    const [planos, config, despesas, vendas, progresso, simulacoes] = await Promise.all([
      buscar('planos_inicio?select=cultura_nome,data_inicio,organico'),
      buscar('cultura_config?select=cultura_nome,safra,area_ha,produtividade'),
      buscar('expenses?select=valor,cultura_nome&order=data.desc&limit=25'),
      buscar('sales?select=valor_total,cultura_nome&order=data.desc&limit=25'),
      buscar('plano_progresso?select=cultura_nome,feito'),
      buscar('simulacoes?select=cultura_nome,lucro_safra,margem_pct&order=criado_em.desc&limit=3'),
    ]);

    const partes = [];

    if (planos.length) {
      const linhas = planos.map((p) => {
        const inicio = p.data_inicio ? new Date(p.data_inicio).toLocaleDateString('pt-BR') : 'data não informada';
        return `${p.cultura_nome} (início ${inicio}${p.organico ? ', orgânico' : ''})`;
      });
      partes.push(`Culturas em andamento: ${linhas.join('; ')}.`);
    }

    if (config.length) {
      const linhas = config.map(
        (c) => `${c.cultura_nome}${c.safra ? ` (${c.safra})` : ''}: ${c.area_ha ? `${c.area_ha} ha` : 'área não informada'}`
      );
      partes.push(`Áreas configuradas: ${linhas.join('; ')}.`);
    }

    if (progresso.length) {
      const porCultura = {};
      progresso.forEach((p) => {
        if (!porCultura[p.cultura_nome]) porCultura[p.cultura_nome] = { total: 0, feito: 0 };
        porCultura[p.cultura_nome].total += 1;
        if (p.feito) porCultura[p.cultura_nome].feito += 1;
      });
      const linhas = Object.entries(porCultura).map(([nome, v]) => `${nome} ${v.feito}/${v.total} etapas concluídas`);
      partes.push(`Progresso do plano: ${linhas.join('; ')}.`);
    }

    const totalDespesas = despesas.reduce((s, d) => s + (Number(d.valor) || 0), 0);
    const totalVendas = vendas.reduce((s, v) => s + (Number(v.valor_total) || 0), 0);
    if (despesas.length || vendas.length) {
      partes.push(
        `Financeiro recente: ${despesas.length} lançamentos de despesa somando aprox. R$ ${totalDespesas.toFixed(2)}; ` +
          `${vendas.length} vendas somando aprox. R$ ${totalVendas.toFixed(2)}; saldo aproximado R$ ${(totalVendas - totalDespesas).toFixed(2)}.`
      );
    }

    if (simulacoes.length) {
      const linhas = simulacoes.map(
        (s) => `${s.cultura_nome} (margem ${s.margem_pct}%, lucro por safra R$ ${Number(s.lucro_safra).toFixed(2)})`
      );
      partes.push(`Últimas simulações: ${linhas.join('; ')}.`);
    }

    return partes.join('\n');
  } catch (e) {
    return '';
  }
}

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'method_not_allowed' });
    return;
  }

  let body;
  try {
    body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
  } catch (e) {
    res.status(400).json({ error: 'json_invalido' });
    return;
  }

  const { messages, cultura, regiao, accessToken } = body || {};

  if (!accessToken) {
    res.status(401).json({ error: 'nao_autenticado' });
    return;
  }
  if (!Array.isArray(messages) || messages.length === 0) {
    res.status(400).json({ error: 'mensagens_invalidas' });
    return;
  }
  if (!process.env.ANTHROPIC_API_KEY) {
    res.status(500).json({ error: 'chave_nao_configurada' });
    return;
  }

  // 1) Checa e registra uso diário via função no banco (RPC segura, roda como SECURITY DEFINER).
  let uso;
  try {
    const rpcRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/chat_registrar_uso`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        apikey: SUPABASE_ANON_KEY,
        Authorization: `Bearer ${accessToken}`,
      },
      body: JSON.stringify({ limite: 20 }),
    });
    uso = await rpcRes.json();
  } catch (e) {
    res.status(500).json({ error: 'erro_verificacao_limite' });
    return;
  }

  if (!uso || uso.permitido !== true) {
    res.status(429).json({
      error: 'limite_diario_atingido',
      usadas: uso ? uso.usadas : undefined,
      limite: (uso && uso.limite) || 20,
    });
    return;
  }

  // 2) Busca o contexto real do produtor (culturas, progresso, financeiro) em paralelo com o resto.
  const contextoUsuario = await montarContextoUsuario(accessToken);

  // 3) Monta o prompt do especialista e chama a API da Anthropic.
  const contextoCultura = cultura && cultura.nome
    ? `Esta conversa foi aberta a partir da página de ${cultura.nome}${regiao && regiao.label ? ` (região ${regiao.label} do Brasil)` : ''}, então se a pergunta do produtor for genérica (ex: "quando adubar?", "como controlar praga?") sem citar outra cultura, assuma que é sobre ${cultura.nome}. Mas isso é só o ponto de partida: você é especialista em TODAS as culturas agrícolas, não só essa. Se o produtor perguntar sobre qualquer outra cultura (ex: café, soja, milho, etc.), responda normalmente e com a mesma qualidade, sem restringir a conversa à cultura da página. `
    : '';

  const sistema =
    'Você é a Easy, assistente agronômica pessoal do aplicativo CultivAI, que ajuda pequenos e médios produtores rurais brasileiros. Se perguntarem seu nome, diga que é Easy. ' +
    'O produtor já viu sua saudação inicial na tela ao abrir o chat — não se reapresente, não repita "eu sou a Easy" nem liste de novo o que você faz; vá direto responder o que ele perguntar ou disser. ' +
    contextoCultura +
    (contextoUsuario
      ? `\n\nVocê tem acesso ao perfil real deste produtor no CultivAI. Use essas informações sempre que ajudarem a personalizar a resposta (ex: mencionar a cultura certa, comentar o progresso do plano, relacionar com o financeiro dele), mas sem citar nomes de tabelas, IDs ou termos técnicos de banco de dados — fale como quem já sabe o que está acontecendo na propriedade dele:\n${contextoUsuario}\n\n`
      : '') +
    'Responda sempre em português do Brasil, de forma direta, prática e objetiva — normalmente 2 a 5 frases, sem enrolação. ' +
    'Foque em orientação agronômica aplicável: manejo, controle de pragas e doenças, solo e adubação, irrigação, poda, colheita, pós-colheita e comercialização. ' +
    'Quando o produtor enviar uma foto de folha, fruto ou planta, observe atentamente sinais visuais (manchas, descoloração, deformação, insetos, fungos, teias, furos) e dê um diagnóstico provável com o grau de confiança (ex: "possivelmente", "sinais consistentes com"), seguido de recomendação prática do que fazer. Nunca afirme um diagnóstico com certeza absoluta apenas pela foto — deixe claro que é uma avaliação visual preliminar e que, em casos graves ou incertos, o ideal é levar amostra a um agrônomo ou à Emater/Ematerce local. ' +
    'Você não tem acesso a cotações de mercado em tempo real nem a previsão do tempo atual — se perguntarem sobre preços ou clima ao vivo, explique isso e oriente onde o produtor pode checar (Ceasa local, Conab, ou o próprio card de previsão do tempo do app). ' +
    'Formatação: para respostas com múltiplos passos, causas ou itens, use marcadores com "- " no início da linha e destaque termos-chave com **negrito**. Para respostas curtas e diretas, não force formatação. ' +
    'Se a pergunta fugir totalmente do tema agrícola, redirecione com gentileza de volta para o cultivo. ' +
    'Depois de responder, avalie se faz sentido sugerir até 2 perguntas de continuação relacionadas à resposta que você acabou de dar (ex: um próximo passo lógico, ou um tema relacionado). Se fizer sentido, adicione uma quebra de linha no final seguida exatamente de [SUGESTOES] e depois um array JSON válido, sem nada mais depois, no formato [{"tag":"Adubação","pergunta":"Como adubar corretamente nessa fase?"},{"tag":"Pragas","pergunta":"Como identificar pragas comuns nessa cultura?"}]. As tags devem ter 1 a 2 palavras, curtas o suficiente pra caber num botão. Não force isso em toda resposta — pule em respostas curtas, de saudação, ou quando não houver um próximo passo natural.';

  // Valida mensagens: aceita texto simples (string) ou blocos multimodais (array com texto/imagem).
  const ALLOWED_IMAGE_TYPES = ['image/jpeg', 'image/png', 'image/webp'];
  const MAX_IMAGE_BASE64_CHARS = 6_000_000; // ~4.5MB de imagem decodificada, folga de segurança
  function mensagemValida(m) {
    if (!m || (m.role !== 'user' && m.role !== 'assistant')) return false;
    if (typeof m.content === 'string') return true;
    if (!Array.isArray(m.content)) return false;
    return m.content.every((bloco) => {
      if (bloco.type === 'text') return typeof bloco.text === 'string';
      if (bloco.type === 'image') {
        const src = bloco.source;
        return (
          src &&
          src.type === 'base64' &&
          ALLOWED_IMAGE_TYPES.includes(src.media_type) &&
          typeof src.data === 'string' &&
          src.data.length <= MAX_IMAGE_BASE64_CHARS
        );
      }
      return false;
    });
  }

  try {
    const anthropicRes = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': process.env.ANTHROPIC_API_KEY,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: 'claude-haiku-4-5-20251001',
        max_tokens: 650,
        system: sistema,
        messages: messages
          .filter(mensagemValida)
          .slice(-20)
          .map((m) => ({ role: m.role, content: m.content })),
      }),
    });

    if (!anthropicRes.ok) {
      const errText = await anthropicRes.text();
      console.error('Anthropic API error', anthropicRes.status, errText);
      res.status(502).json({ error: 'erro_ia' });
      return;
    }

    const data = await anthropicRes.json();
    let texto = (data.content || [])
      .filter((b) => b.type === 'text')
      .map((b) => b.text)
      .join('\n')
      .trim();

    // Separa o texto principal das sugestões de perguntas (se o modelo incluiu).
    let sugestoes = null;
    const marcador = '[SUGESTOES]';
    const posMarcador = texto.indexOf(marcador);
    if (posMarcador !== -1) {
      const parteTexto = texto.slice(0, posMarcador).trim();
      const parteJson = texto.slice(posMarcador + marcador.length).trim();
      try {
        const parsed = JSON.parse(parteJson);
        if (Array.isArray(parsed)) {
          sugestoes = parsed
            .filter((s) => s && typeof s.tag === 'string' && typeof s.pergunta === 'string')
            .slice(0, 2);
          if (!sugestoes.length) sugestoes = null;
        }
      } catch (e) {
        // JSON malformado: ignora sugestões, mantém só o texto principal.
      }
      texto = parteTexto;
    }

    res.status(200).json({ texto, sugestoes, usadas: uso.usadas, limite: uso.limite });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: 'erro_interno' });
  }
};
