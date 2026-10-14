# Beispiel 1: eigenes Image bauen
#
#   cd ~/docker-kurs/beispiele/01-webseite
#   docker build -t meine-webseite .
#   docker run -d --name webseite -p $MEIN_PORT:80 meine-webseite
#   curl localhost:$MEIN_PORT
#
# Danach index.html aendern, neu bauen und den Container ersetzen:
#   docker rm -f webseite
#   docker build -t meine-webseite . && docker run -d --name webseite -p $MEIN_PORT:80 meine-webseite

FROM nginx:1.27-alpine

COPY index.html /usr/share/nginx/html/index.html

EXPOSE 80
