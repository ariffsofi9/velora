import {generateKeyPairSync,sign,verify} from 'node:crypto';
export function syntheticIdentity(now) {
  const pair=generateKeyPairSync('rsa',{modulusLength:2048});
  const der=(tag,...parts)=>{
    const bytes=Buffer.concat(parts); let length=bytes.length; const list=[];
    if(length>=128) {while(length){list.unshift(length&255);length>>>=8;} list.unshift(128+list.length);} else list.push(length);
    return Buffer.concat([Buffer.from([tag,...list]),bytes]);
  };
  const seq=(...p)=>der(48,...p);
  const algorithm=seq(der(6,Buffer.from('2a864886f70d01010b','hex')),der(5));
  const name=seq(der(49,seq(der(6,Buffer.from('550403','hex')),der(12,Buffer.from('Offline synthetic')))));
  const tbs=seq(der(2,Buffer.from([1])),algorithm,name,seq(der(23,Buffer.from('250101000000Z')),der(23,Buffer.from('350101000000Z'))),name,pair.publicKey.export({format:'der',type:'spki'}));
  const cert=seq(tbs,algorithm,der(3,Buffer.from([0]),sign('RSA-SHA256',tbs,pair.privateKey)));
  const encode=x=>Buffer.from(JSON.stringify(x)).toString('base64url');
  return {certificate:'-----BEGIN CERTIFICATE-----\n'+cert.toString('base64').match(/.{1,64}/g).join('\n')+'\n-----END CERTIFICATE-----',
    sign:bytes=>sign('RSA-SHA256',bytes,pair.privateKey),
    verifyAssertion(body){const token=new URLSearchParams(body).get('assertion').split('.');if(!verify('RSA-SHA256',Buffer.from(token.slice(0,2).join('.')),pair.publicKey,Buffer.from(token[2],'base64url')))throw Error('assertion');},
    token(uid='owner',changes={}){
      const time=Math.floor(now()/1000);
      const unsigned=encode({alg:'RS256',kid:'synthetic'})+'.'+encode({sub:uid,aud:'velora-spark-test',iss:'https://securetoken.google.com/velora-spark-test',iat:time,auth_time:time,exp:time+3600,email:uid+'@example.test',email_verified:true,...changes});
      return unsigned+'.'+sign('RSA-SHA256',Buffer.from(unsigned),pair.privateKey).toString('base64url');
    }};
}
