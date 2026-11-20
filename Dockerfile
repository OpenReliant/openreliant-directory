FROM scratch
ARG TARGETARCH
COPY dist/${TARGETARCH}/openreliant-directory /openreliant-directory
USER 65532:65532
EXPOSE 8080/tcp
ENTRYPOINT ["/openreliant-directory"]
CMD ["--bind", "0.0.0.0:8080"]
