ARG ERLANG_VERSION=27.3.4.2
ARG GLEAM_VERSION=v1.16.0

FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-scratch AS gleam

FROM erlang:${ERLANG_VERSION}-alpine AS build
COPY --from=gleam /bin/gleam /bin/gleam
COPY . /app/
RUN cd /app && gleam export erlang-shipment

FROM erlang:${ERLANG_VERSION}-alpine
RUN \
  addgroup --system webapp && \
  adduser --system webapp -g webapp

COPY healthcheck.sh /app/healthcheck.sh
RUN chmod +x /app/healthcheck.sh
COPY --from=build /app/build/erlang-shipment /app
WORKDIR /app
USER webapp

HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD ["/bin/sh", "/app/healthcheck.sh"]
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
