
DOMAIN="*.tmc.ragazzilab.com"
SUBJ="/C=US/ST=MS/L=Madison/O=Ragazzi/OU=Lab/CN=${DOMAIN}"


openssl genrsa -out ca.key 4096

openssl req -x509 -new -nodes -key ca.key -sha512 -days 3650 -out tmcsm-ca.crt -subj "$SUBJ"

openssl genrsa -out server-app.key 4096

openssl req -sha512 -new -subj "$SUBJ" -key server-app.key -out server-app.csr

cat > v3.ext <<-EOF
  authorityKeyIdentifier=keyid,issuer
  basicConstraints=CA:FALSE
  keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
  extendedKeyUsage = serverAuth
  subjectAltName = @alt_names
  [alt_names]
  DNS.1=${DOMAIN}
EOF

#openssl x509 -req -sha512 -days 3650 -passin pass:1234 -extfile v3.ext -CA tmcsm-ca.crt -CAkey ca.key -CAcreateserial -in server-app.csr -out server-app.crt
openssl x509 -req -sha512 -days 3650 -extfile v3.ext -CA tmcsm-ca.crt -CAkey ca.key -CAcreateserial -in server-app.csr -out server-app.crt
