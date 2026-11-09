// Teste de paridade: calcAntigo (lógica atual do CalcScreen) x calcularSimulacao (novo núcleo)
const fs = require("fs");
const Babel = require("/home/claude/harness/node_modules/@babel/standalone");
const src = fs.readFileSync("/tmp/app.pretty.jsx", "utf8").split("\n");
function slice(a, b) { return src.slice(a - 1, b).join("\n"); }
function lineOf(re, from = 0) { for (let i = from; i < src.length; i++) if (re.test(src[i])) return i + 1; return -1; }
// pega as constantes necessárias
const L = {};
["REGIOES", "VERDURAS", "COGUMELOS", "APICULTURA", "FLORES", "HIDROPONIA", "SILVICULTURA", "TEMPEROS", "ESTUFA_PERFIL", "IMPLANT_CATEGORIAS", "MANEJO_CATEGORIAS"].forEach((n) => { L[n] = lineOf(new RegExp("^const " + n + " = ")); });
function blockEnd(start) { // acha o fim do bloco iniciado em start (fecha com ']' ou '}' + ';' na coluna 0)
  for (let i = start; i < src.length; i++) { if (/^(\]|\});?\s*$/.test(src[i])) return i + 1; } return -1; }
let code = "const GH=\"\";\n";
Object.keys(L).forEach((n) => { code += slice(L[n], blockEnd(L[n])) + "\n"; });
const pe = lineOf(/^function perfilEstufa/);
code += slice(pe, pe + 5) + "\n";
code += fs.readFileSync("/home/claude/calc_new/calc_core.jsx", "utf8");
code += `
function calcAntigo(cultura, e){
  const cv=e.cv; const prodHa=e.prodHa; const area=e.area;
  const custImpl = IMPLANT_CATEGORIAS.reduce((s,c)=>s+(Number(e.implantItens[c.id])||0),0);
  const custManejo = MANEJO_CATEGORIAS.reduce((s,c)=>s+(Number(e.manejoItens[c.id])||0),0);
  const precoA=e.precoA, precoV=e.precoV, pctA=e.pctA, organico=!!e.organico;
  const perfilEst = perfilEstufa(cultura);
  const estufaAtiva = e.estufa && !!perfilEst;
  const fE = estufaAtiva ? Math.min(100, Math.max(0, e.estufaFracao)) / 100 : 0;
  const fProdE = 1 + (perfilEst ? perfilEst.ganhoProd : 0) * fE, fPrecoE = 1 + (perfilEst ? perfilEst.ganhoPreco : 0) * fE, fManejoE = 1 + (perfilEst ? perfilEst.manejoExtra : 0) * fE;
  const estufaAreaM2 = estufaAtiva ? Math.round(area * fE) : 0;
  const estufaInvest = estufaAtiva ? estufaAreaM2 * (Number(e.estufaCustoM2) || 0) : 0;
  const estufaCustoSafra = estufaAtiva && perfilEst ? estufaInvest / ((perfilEst.vidaUtilAnos || 10) * cultura.safras) : 0;
  const custImplEf = organico ? Math.round(custImpl * 1.2) : custImpl, custManejoBaseEf = organico ? Math.round(custManejo * 1.15) : custManejo, custManejoEf = Math.round(custManejoBaseEf * fManejoE), precoABase = organico ? +(precoA * 1.3).toFixed(2) : precoA, precoVBase = organico ? +(precoV * 1.3).toFixed(2) : precoV, precoAEf = +(precoABase * fPrecoE).toFixed(2), precoVEf = +(precoVBase * fPrecoE).toFixed(2), prodHaEf = Math.round(prodHa * fProdE);
  const ha = area / 10000, implT = custImplEf * ha, manejoS = custManejoEf * ha;
  const moRatio = cultura.tipoCultivo === "cogumelo" ? 0.2 : cultura.dificuldade === "Difícil" ? 0.4 : cultura.dificuldade === "Médio" ? 0.75 : 1.5, moRecomendado = Math.max(1, Math.round(ha / moRatio) || 1), moTrabalhadoresEf = e.moTrabalhadores != null ? e.moTrabalhadores : moRecomendado;
  const moPeriodoMesesSugerido = cultura.ciclo <= 12 ? 2 : Math.max(2, Math.round(cultura.ciclo * 0.15));
  const moPeriodoMeses = e.moPeriodoMeses!=null?e.moPeriodoMeses:moPeriodoMesesSugerido;
  const moPeriodo = e.moModo === "mensal" ? moPeriodoMeses : e.moPeriodoDias, moValorEfetivo = e.moModo === "mensal" ? e.moValor : e.moValorDiaria, moCustoBase = moTrabalhadoresEf * moValorEfetivo * moPeriodo, maoDeObraT = e.moEncargosIncluir ? moCustoBase * (1 + e.moEncargosPct / 100) : moCustoBase;
  const custoT = implT + manejoS + maoDeObraT + estufaCustoSafra, prodT = ha * prodHaEf, kgA = (prodT * pctA) / 100, kgV = prodT - kgA, recT = kgA * precoAEf + kgV * precoVEf, lucro = recT - custoT, lucroAno = lucro * cultura.safras, margem = recT > 0 ? (lucro / recT) * 100 : 0;
  return {custoT,recT,lucro,lucroAno,margem,maoDeObraT,moPeriodoMesesSugerido};
}
const todas=[...REGIOES.flatMap(rg=>rg.culturas.map(c=>({c,rg}))),...[VERDURAS,TEMPEROS,COGUMELOS,APICULTURA,FLORES,HIDROPONIA,SILVICULTURA].flatMap(g=>g.culturas.map(c=>({c,rg:{id:'geral',label:g.label}})))];
function entrada(c, cv, cen, extra){
  const impl={},man={};IMPLANT_CATEGORIAS.forEach(k=>impl[k.id]=Math.round(c.custImpl*k.pct));MANEJO_CATEGORIAS.forEach(k=>man[k.id]=Math.round(c.custManejo*k.pct));
  return Object.assign({cv,area:10000,prodHa:Math.round(cv.prod*cen),implantItens:impl,manejoItens:man,precoA:c.precoA,precoV:c.precoV,pctA:60,moTrabalhadores:null,moModo:'mensal',moValor:1518,moValorDiaria:150,moPeriodoMeses:null,moPeriodoDias:null,moEncargosIncluir:false,moEncargosPct:38,organico:false,estufa:false,estufaFracao:100,estufaCustoM2:0,formaVenda:null},extra||{});
}
let n=0,diff=0,perenes=[],mesesMud=[];
for(const {c,rg} of todas){
  for(const cv of c.cultivares){
    for(const cen of [0.85,1,1.15]){
      for(const extra of [{},{organico:true},{estufa:true,estufaFracao:100,estufaCustoM2:(ESTUFA_PERFIL[c.nome]||{}).custoM2||0}]){
        const e=entrada(c,cv,cen,extra);
        const A=calcAntigo(c,e);
        // mesma base: força meses antigos e ignora perene/forma pra testar paridade pura
        const e2=Object.assign({},e,{moPeriodoMeses:A.moPeriodoMesesSugerido});
        const cAnual=Object.assign({},c,{perene:false});
        const N=calcularSimulacao(cAnual,rg,e2);
        n++;
        const ok=['custoT','recT','lucro','lucroAno','margem','maoDeObraT'].every(k=>Math.abs(A[k]-N[k])<0.01);
        if(!ok){diff++; if(diff<6)console.log('DIFF',c.nome,cv.name,cen,JSON.stringify(extra),A,{custoT:N.custoT,recT:N.recT,lucro:N.lucro});}
      }
    }
  }
  if(ehPerene(c)) perenes.push(c.nome);
  const mAnt=c.ciclo<=12?2:Math.max(2,Math.round(c.ciclo*0.15)); const mNovo=mesesMaoDeObraSugerido(c); if(mAnt!==mNovo) mesesMud.push(c.nome+' '+mAnt+'→'+mNovo+' (ciclo '+c.ciclo+')');
}
console.log('casos',n,'diferencas',diff);
console.log('perenes ('+[...new Set(perenes)].length+'):',[...new Set(perenes)].join(', '));
console.log('meses de mao de obra mudam em',[...new Set(mesesMud)].length,'culturas:',[...new Set(mesesMud)].slice(0,40).join('; '));
// amostra perene
const cafe=todas.find(x=>x.c.nome==='Café'); const e=entrada(cafe.c,cafe.c.cultivares[0],1,{});
const R=calcularSimulacao(cafe.c,cafe.rg,e); console.log('CAFE novo: lucro safra',Math.round(R.lucro),'primeira',Math.round(R.lucroPrimeira),'retorno',R.retornoSafras&&R.retornoSafras.toFixed(2),'faixa',Math.round(R.faixa.min),Math.round(R.faixa.max),'veredito',R.veredito,'forma',R.forma&&R.forma.id);
const tom=todas.find(x=>x.c.nome==='Tomate'); const et=entrada(tom.c,tom.c.cultivares[0],1,{}); const T=calcularSimulacao(tom.c,tom.rg,et); console.log('TOMATE: lucro',Math.round(T.lucro),'rec',Math.round(T.recT),'custo',Math.round(T.custoT),'mo',Math.round(T.maoDeObraT),'meses',T.moPeriodoMeses,'faixa',Math.round(T.faixa.min),Math.round(T.faixa.max),T.veredito);
`;
const out = Babel.transform(code, { presets: ["env"] }).code;
new Function("require", out)(require);
