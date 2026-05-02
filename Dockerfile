FROM alpine:3.21

WORKDIR /app

ARG TARGETOS
ARG TARGETARCH

COPY komari-agent-${TARGETOS}-${TARGETARCH} /app/komari-agent
RUN chmod +x /app/komari-agent && touch /.komari-agent-container

ENTRYPOINT ["/app/komari-agent"]
CMD ["--help"]
