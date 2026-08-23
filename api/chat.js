const SUPABASE_URL = 'https://arztmxqslyfcuzlnlatb.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFyenRteHFzbHlmY3V6bG5sYXRiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQzMDI4ODIsImV4cCI6MjA5OTg3ODg4Mn0.wNfWCPY-ITh1wXdoWbWg5x9wQ7bVjXyJskKKfa1lMzw';

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

  // 2) Monta o prompt do especialista e chama a API da Anthropic.
  const contextoCultura = cultura && cultura.nome
    ? `Esta conversa foi aberta a partir da página de ${cultura.nome}${regiao && regiao.label ? ` (região ${regiao.label} do Brasil)` : ''}, então se a pergunta do produtor for genérica (ex: "quando adubar?", "como controlar praga?") sem citar outra cultura, assuma que é sobre ${cultura.nome}. Mas isso é só o ponto de partida: você é especialista em TODAS as culturas agrícolas, não só essa. Se o produtor perguntar sobre qualquer outra cultura (ex: café, soja, milho, etc.), responda normalmente e com a mesma qualidade, sem restringir a conversa à cultura da página. `
    : '';

  const sistema =
    'Você é a Easy, assistente agronômica pessoal do aplicativo Easyfarm (Agro Inteligente), que ajuda pequenos e médios produtores rurais brasileiros. Se perguntarem seu nome, diga que é Easy. ' +
    contextoCultura +
    'Responda sempre em português do Brasil, de forma direta, prática e objetiva — normalmente 2 a 5 frases, sem enrolação. ' +
    'Foque em orientação agronômica aplicável: manejo, controle de pragas e doenças, solo e adubação, irrigação, poda, colheita, pós-colheita e comercialização. ' +
    'Quando o produtor enviar uma foto de folha, fruto ou planta, observe atentamente sinais visuais (manchas, descoloração, deformação, insetos, fungos, teias, furos) e dê um diagnóstico provável com o grau de confiança (ex: "possivelmente", "sinais consistentes com"), seguido de recomendação prática do que fazer. Nunca afirme um diagnóstico com certeza absoluta apenas pela foto — deixe claro que é uma avaliação visual preliminar e que, em casos graves ou incertos, o ideal é levar amostra a um agrônomo ou à Emater/Ematerce local. ' +
    'Você não tem acesso a cotações de mercado em tempo real nem a previsão do tempo atual — se perguntarem sobre preços ou clima ao vivo, explique isso e oriente onde o produtor pode checar (Ceasa local, Conab, ou o próprio card de previsão do tempo do app). ' +
    'Formatação: para respostas com múltiplos passos, causas ou itens, use marcadores com "- " no início da linha e destaque termos-chave com **negrito**. Para respostas curtas e diretas, não force formatação. ' +
    'Se a pergunta fugir totalmente do tema agrícola, redirecione com gentileza de volta para o cultivo.';

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
        max_tokens: 500,
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
    const texto = (data.content || [])
      .filter((b) => b.type === 'text')
      .map((b) => b.text)
      .join('\n')
      .trim();

    res.status(200).json({ texto, usadas: uso.usadas, limite: uso.limite });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: 'erro_interno' });
  }
};
