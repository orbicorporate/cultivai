const CACHE='cultivai-v1';
const ASSETS=['/','/index.html','/manifest.json'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(CACHE).then(c=>c.addAll(ASSETS)));self.skipWaiting();});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))));self.clients.claim();});
self.addEventListener('fetch',e=>{e.respondWith(caches.match(e.request).then(cached=>cached||fetch(e.request)));});self.addEventListener('push',e=>{let data={title:'CultivAI',body:'Você tem avisos pendentes',url:'/'};try{data=e.data.json();}catch(err){}e.waitUntil(self.registration.showNotification(data.title,{body:data.body,icon:'/icon-192.png',badge:'/icon-192.png',data:{url:data.url||'/'}}));});
self.addEventListener('notificationclick',e=>{e.notification.close();e.waitUntil(clients.matchAll({type:'window'}).then(clientList=>{for(const c of clientList){if('focus' in c)return c.focus();}if(clients.openWindow)return clients.openWindow(e.notification.data.url||'/');}));});
