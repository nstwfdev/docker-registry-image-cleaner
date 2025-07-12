FROM alpine:3.20

RUN apk add --no-cache bash curl jq coreutils

COPY clean.sh /usr/local/bin/clean.sh
RUN chmod +x /usr/local/bin/clean.sh

ENTRYPOINT ["/usr/local/bin/clean.sh"]