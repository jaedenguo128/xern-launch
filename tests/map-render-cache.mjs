import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';

const html=await readFile(new URL('../index.html',import.meta.url),'utf8');
let resizes=0,canvasCopies=0,staticDraws=0;
function makeCanvas(){
  let width=300,height=150;
  const canvas={clientWidth:900,clientHeight:600};
  Object.defineProperties(canvas,{width:{get:()=>width,set:v=>{width=v;resizes++;}},height:{get:()=>height,set:v=>{height=v;resizes++;}}});
  const ctx=new Proxy({
    fillStyle:'#000000',image:null,
    createImageData:(w,h)=>({data:new Uint8ClampedArray(w*h*4),width:w,height:h}),
    putImageData(image){this.image=image;},
    getImageData(){const color=this.fillStyle;return {data:Uint8ClampedArray.from([parseInt(color.slice(1,3),16),parseInt(color.slice(3,5),16),parseInt(color.slice(5,7),16),255])};},
    drawImage(){canvasCopies++;},fillRect(){staticDraws++;},measureText:()=>({width:50}),
  },{get:(t,k)=>k in t?t[k]:(()=>{})});
  canvas.getContext=()=>ctx;
  return canvas;
}
const frames=[],mapCanvas=makeCanvas();
const state={
  Math,Map,Set,Uint8ClampedArray,JSON,Number,String,Object,Date,
  nativeCanvas:mapCanvas,nativeCtx:mapCanvas.getContext('2d'),nativeReady:true,
  nativeCenter:{lng:0,lat:0},nativeZoom:10,nativeSquareLand:{},nativeMaskPixels:null,
  LAND_X_COUNT:8897,LAND_Y_COUNT:2832,devicePixelRatio:1,
  landUserId:'a',landHoldings:{},clanColorsByOwner:{a:'#a348d9',b:'#40a0f0',c:'#e0c050'},
  nativeEnemyWalkers:[],warfareAssets:[],warfareCombatFx:[],landRallyLatLng:null,landFirstPlot:null,
  document:{hidden:false,createElement:()=>makeCanvas()},$:(id)=>({hidden:false}),
  requestAnimationFrame:fn=>{frames.push(fn);return frames.length;},
  landHomebaseKey:()=>'',nativePlotIsLand:()=>true,
};
vm.createContext(state);
for(const name of ['landLon','landLat','landPlotCoords','nativeMerc','nativeInvMerc','nativeSize','nativeScale','nativeYScale','nativeProject','nativeUnproject','nativePlotPosition','nativeOwnerColor']){
  const line=html.match(new RegExp('  function '+name+'\\([^\\n]+'));
  assert(line,'Missing map function '+name);vm.runInContext(line[0],state);
}
const start=html.indexOf('  // Ownership is indexed once per snapshot;');
const end=html.indexOf('  function drawXernEquipment(',start);
assert(start>=0&&end>start);vm.runInContext(html.slice(start,end),state);

// Three substantial colonies: frame work must not scale with all 300,000 keys.
const holdings={};
for(let y=1100;y<1400;y++)for(let x=3500;x<4500;x++){
  holdings['plot:'+x+':'+y]={owner_id:['a','b','c'][Math.min(2,Math.floor((x-3500)/334))],owner_name:'Player',paid:0};
}
let forbidScan=false;
state.landHoldings=new Proxy(holdings,{ownKeys(target){assert(!forbidScan,'Animation or panning scanned every claim');return Reflect.ownKeys(target);}});
state.nativeCenter={lng:state.landLon(4000),lat:state.landLat(1250)};
state.nativePaintGrid();
assert.equal(state.nativeGetMapIndex().keys.length,300000);
const first=state.nativeGetMapIndex();
assert.equal(first.owners.size,3);
const mine=holdings['plot:3800:1250'];
let chunk=first.chunks.get(Math.floor(mine._x/64)+':'+Math.floor(mine._y/64));
function pixel(h,chunk){const at=((h._y%64)*64+h._x%64)*4;return Array.from(chunk.canvas.getContext('2d').image.data.slice(at,at+4));}
assert.deepEqual(pixel(mine,chunk),[163,72,217,255]);

forbidScan=true;
const initialResizes=resizes,initialStaticDraws=staticDraws,initialCopies=canvasCopies;
for(let i=0;i<30;i++)state.nativePaintGrid();
assert.equal(resizes,initialResizes,'Animation must not resize canvas each frame');
assert.equal(staticDraws,initialStaticDraws,'Animation must reuse the cached territory layer');
assert.equal(canvasCopies-initialCopies,30,'Each frame copies the cached viewport once');
state.nativeCenter.lng+=.2;state.nativePaintGrid();
assert.strictEqual(state.nativeGetMapIndex(),first);
assert(staticDraws>initialStaticDraws,'Panning must update the visible viewport');

state.landRenderGrid();state.landRenderGrid();state.landRenderGrid();
assert.equal(frames.length,1,'Drag events must coalesce into one animation frame');frames.shift()();
state.clanColorsByOwner.a='#112233';state.nativePaintGrid();
assert.deepEqual(pixel(mine,chunk),[17,34,51,255],'Clan color changes must invalidate textures');

// A fresh authoritative snapshot must remove old territory and player labels.
state.landHoldings={'plot:4000:1250':{owner_id:'b',owner_name:'New owner',paid:0}};
state.nativePaintGrid();
assert.equal(state.nativeGetMapIndex().keys.length,1);
assert.equal(state.nativeGetMapIndex().owners.size,1);
assert.equal(state.nativeOwnerLand('a').length,0);
assert.equal(state.nativeOwnerLand('b').length,1);
console.log('PASS 300k-claim chunk rendering, no full-world frame scans, bitmap reuse, drag coalescing, colors and ownership replacement');
