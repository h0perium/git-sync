FROM alpine:3.19

RUN apk add --no-cache git openssh-client bash curl jq
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
