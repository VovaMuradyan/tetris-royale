FROM golang:1.22-alpine AS build

RUN apk add --no-cache ca-certificates git
WORKDIR /src

COPY go.mod ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/tetris-royale .

FROM alpine:3.20

RUN apk add --no-cache ca-certificates
COPY --from=build /out/tetris-royale /usr/local/bin/tetris-royale

ENV PORT=8080
EXPOSE 8080

CMD ["tetris-royale"]
