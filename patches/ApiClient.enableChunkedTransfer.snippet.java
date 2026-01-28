    private static volatile boolean chunkedTransfer = false;

    /**
     * Enable chunked transfer encoding for multipart uploads (file parameters).
     *
     * When enabled, multipart request bodies are streamed using chunked
     * transfer encoding (no Content-Length header). When disabled (the default),
     * bodies are buffered to a byte array so a known Content-Length is sent.
     *
     * @return this ApiClient instance for method chaining
     */
    public ApiClient enableChunkedTransfer() {
        chunkedTransfer = true;
        return this;
    }

    /**
     * Check whether chunked transfer encoding is enabled.
     *
     * @return true if chunked transfer is enabled
     */
    public static boolean isChunkedTransferEnabled() {
        return chunkedTransfer;
    }
