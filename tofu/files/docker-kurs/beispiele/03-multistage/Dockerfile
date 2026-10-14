# Beispiel 3: Multi-Stage-Build
#
#   cd ~/docker-kurs/beispiele/03-multistage
#   docker build -t hallo-go .
#   docker run -d --name hallo -p $((MEIN_PORT + 1)):8080 hallo-go
#   curl localhost:$((MEIN_PORT + 1))
#
# Groesse vergleichen:
#   docker images golang:1.23-alpine     Build-Image mit Compiler (~250 MB)
#   docker images hallo-go               fertiges Image (nur wenige MB)

# Stufe 1: kompilieren. Der Compiler landet NICHT im fertigen Image.
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY main.go .
RUN CGO_ENABLED=0 go build -o /hallo main.go

# Stufe 2: nur das statische Programm, sonst nichts - nicht einmal eine Shell.
FROM scratch
COPY --from=build /hallo /hallo
EXPOSE 8080
ENTRYPOINT ["/hallo"]
