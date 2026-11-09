const {chromium}=require('playwright-core');const fs=require('fs');const path=require('path');
const ROOT='/home/claude/cultivai';const NM='/home/claude/harness/node_modules';
const CDN={'supabase.js':null,'jspdf.umd.min.js':NM+'/jspdf/dist/jspdf.umd.min.js','react.production.min.js':NM+'/react/umd/react.production.min.js','react-dom.production.min.js':NM+'/react-dom/umd/react-dom.production.min.js','babel.min.js':NM+'/@babel/standalone/babel.min.js'};
const mime={'.html':'text/html','.js':'application/javascript','.css':'text/css','.png':'image/png','.jpg':'image/jpeg','.svg':'image/svg+xml','.json':'application/json','.woff2':'font/woff2'};
(async()=>{
 const browser=await chromium.launch({executablePath:'/usr/bin/google-chrome',args:['--no-sandbox']});
 const stub=fs.readFileSync('stub_sb.js','utf8');const resp=fs.readFileSync('resp_pro.js','utf8');
 for(const width of [360,393]){
  const ctx=await browser.newContext({viewport:{width,height:800},deviceScaleFactor:1,isMobile:true,hasTouch:true});
  await ctx.addInitScript(resp+`;try{localStorage.setItem('cultivai_usou_funcao','1');localStorage.setItem('cultivai_abriu_cultura','1');localStorage.setItem('ef_install_prompt',JSON.stringify({dismissedAt:new Date().toISOString()}));}catch(e){}`);
  await ctx.route('**/*',async route=>{const url=route.request().url();const base=url.split('?')[0].split('/').pop();
   if(url.includes('open-meteo'))return route.fulfill({contentType:'application/json',body:'{}'});
   if(base in CDN){if(CDN[base]===null)return route.fulfill({contentType:'application/javascript',body:stub});return route.fulfill({contentType:'application/javascript',body:fs.readFileSync(CDN[base])});}
   if(url.startsWith('http://app.local/')){let p=decodeURIComponent(url.replace('http://app.local','').split('?')[0]);if(p==='/')p='/index.html';const f=path.join(ROOT,p);if(fs.existsSync(f)&&fs.statSync(f).isFile())return route.fulfill({contentType:mime[path.extname(f)]||'application/octet-stream',body:fs.readFileSync(f)});return route.fulfill({status:404,body:''});}
   return route.fulfill({status:200,body:''});});
  const page=await ctx.newPage();
  await page.goto('http://app.local/index.html');await page.waitForTimeout(2500);
  for(const crop of ['Tomate','Café']){
  await page.evaluate(()=>{const b=[...document.querySelectorAll('button')].find(b=>/Início|Página inicial/.test(b.textContent));if(b)b.click();});await page.waitForTimeout(600);
  await page.getByText('Sudeste',{exact:false}).first().click().catch(()=>{});await page.waitForTimeout(500);
  await page.evaluate((crop)=>{const b=[...document.querySelectorAll('button')].find(b=>new RegExp(crop).test(b.textContent)&&/Lucro por/.test(b.textContent));if(b)b.click();},crop);await page.waitForTimeout(1200);
  for(let n=1;n<=6;n++){
    // abre tudo
    await page.evaluate(()=>{document.querySelectorAll('.cn .sec').forEach(b=>{if(!/PDF|Fechar|Testar/.test(b.textContent))b.click();});});await page.waitForTimeout(250);
    await page.evaluate(()=>{const b=document.querySelector('.cn .row.sq');if(b&&/Adubo/.test(b.textContent))b.click();});await page.waitForTimeout(250);
    const r=await page.evaluate(()=>{const out=[];const sel='.cn .b,.cn .ch,.cn .sec,.cn .tag,.cn .hang,.cn .opt .ot,.cn .row .rt,.cn .sw .st,.cn .stepper .sh,.cn .easy>div';
      function linhas(el){const tops=new Set();const w=document.createTreeWalker(el,NodeFilter.SHOW_TEXT);let t;while((t=w.nextNode())){if(!t.textContent.trim())continue;const r=document.createRange();r.selectNodeContents(t);[...r.getClientRects()].forEach(rc=>{if(rc.width>0)tops.add(Math.round(rc.top/4));});}return tops.size;}
      document.querySelectorAll(sel).forEach(el=>{const over=el.scrollWidth>el.clientWidth+1||el.scrollHeight>el.clientHeight+1;const n=linhas(el);const single=/(^| )(b|ch|sec|tag|hang)( |$)/.test(el.className)&&!/wide/.test(el.className)&&!el.closest('.adj');const limite=single?1:2;if(over||n>limite)out.push(el.className.split(' ').slice(0,2).join('.')+': "'+el.textContent.trim().slice(0,45)+'" '+(over?'OVERFLOW ':'')+n+'L');});return out;});
    if(r.length)console.log(width,crop,'p'+n,r.join(' | '));
    if(n<6){await page.evaluate(()=>{const b=document.querySelector('.cn .b.next');if(b)b.click();});await page.waitForTimeout(500);}
  }}
  await ctx.close();
 }
 await browser.close();console.log('fim');
})();
