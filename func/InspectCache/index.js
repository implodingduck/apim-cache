const redis = require('redis');


module.exports = async function (context, req) {
    context.log('JavaScript HTTP trigger function processed a request.');
    const connarr = process.env.CACHE_CONNSTR.split(",")
    const host_port = connarr[0].split(":")
    const client = redis.createClient(
        {
            url: "rediss://"+connarr[0],
            password: connarr[1].split("password=")[1]
        }
    );
    await client.connect()    
    const cachekey = (req.query.cachekey || (req.body && req.body.cachekey));
    const cacheresp = await client.get(cachekey)
    

    context.res = {
        // status: 200, /* Defaults to 200 */
        body: cacheresp
    };
}