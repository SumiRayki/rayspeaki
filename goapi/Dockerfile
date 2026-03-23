# Build stage
FROM golang:1.24-alpine AS builder
WORKDIR /app
RUN apk add --no-cache git
COPY go.mod ./
RUN go get github.com/jackc/pgx/v5@v5.7.2 github.com/redis/go-redis/v9@v9.7.3 golang.org/x/crypto@v0.35.0
COPY . .
RUN go mod tidy && CGO_ENABLED=0 GOOS=linux go build -o /goapi .

# Runtime stage
FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
COPY --from=builder /goapi /goapi
EXPOSE 3000
CMD ["/goapi"]
