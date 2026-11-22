FROM scratch
ARG TARGETARCH
COPY dist/${TARGETARCH}/openreliant-directory /openreliant-directory
COPY dist/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
USER 65532:65532
EXPOSE 8080/tcp
ENTRYPOINT ["/openreliant-directory"]
# The service expects an HTTPS proxy on the same host. Run the container with host networking.
CMD ["--bind", "127.0.0.1:8080", "--trust-proxy"]
