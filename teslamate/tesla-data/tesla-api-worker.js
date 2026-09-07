const PUBLIC_KEY_PEM = `-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEmlV38V1iIOZC/iOSAPECwLRslvE1
YjhmW9ujKpPcIVF1PzlqkYaqdtZKbyeo+aO1COuWG3w7Xqedeemz5LQR4g==
-----END PUBLIC KEY-----
`;

export default {
  async fetch(request) {
    const { pathname } = new URL(request.url);
    if (pathname === "/.well-known/appspecific/com.tesla.3p.public-key.pem") {
      return new Response(PUBLIC_KEY_PEM, {
        status: 200,
        headers: { "content-type": "application/x-pem-file" },
      });
    }
    return new Response("Not found", { status: 404 });
  },
};