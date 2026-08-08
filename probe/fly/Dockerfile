FROM elixir:1.17-otp-27
ARG FDB=7.3.43
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
 && curl -fsSL -o /tmp/c.deb https://github.com/apple/foundationdb/releases/download/${FDB}/foundationdb-clients_${FDB}-1_amd64.deb \
 && curl -fsSL -o /tmp/s.deb https://github.com/apple/foundationdb/releases/download/${FDB}/foundationdb-server_${FDB}-1_amd64.deb \
 && dpkg -i /tmp/c.deb /tmp/s.deb && rm -rf /var/lib/apt/lists/* /tmp/*.deb
RUN mix local.hex --force && mix local.rebar --force
COPY scaling.exs /scaling.exs
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
