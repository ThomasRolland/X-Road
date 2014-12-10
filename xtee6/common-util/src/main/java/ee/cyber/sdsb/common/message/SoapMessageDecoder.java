package ee.cyber.sdsb.common.message;

import java.io.IOException;
import java.io.InputStream;
import java.util.HashMap;
import java.util.Map;

import lombok.extern.slf4j.Slf4j;

import org.apache.james.mime4j.MimeException;
import org.apache.james.mime4j.parser.AbstractContentHandler;
import org.apache.james.mime4j.parser.MimeStreamParser;
import org.apache.james.mime4j.stream.BodyDescriptor;
import org.apache.james.mime4j.stream.Field;
import org.apache.james.mime4j.stream.MimeConfig;

import ee.cyber.sdsb.common.CodedException;
import ee.cyber.sdsb.common.util.MimeUtils;

import static ee.cyber.sdsb.common.ErrorCodes.*;
import static ee.cyber.sdsb.common.util.MimeTypes.MULTIPART_RELATED;
import static ee.cyber.sdsb.common.util.MimeUtils.*;
import static org.eclipse.jetty.http.MimeTypes.TEXT_XML;

@Slf4j
public class SoapMessageDecoder {

    private final String contentType;
    private final Callback callback;
    private final String baseContentType;
    private final SoapParser parser;

    public interface Callback extends SoapMessageConsumer {

        /** Called when SoapFault has been completely read. */
        void fault(SoapFault fault) throws Exception;

        /** Called when the message has been completely read. */
        void onCompleted();

        /** Called when an error occurred during soap or attachment part. */
        void onError(Exception t) throws Exception;
    }

    public SoapMessageDecoder(String contentType, Callback callback) {
        this(contentType, callback, new SoapParserImpl());
    }

    public SoapMessageDecoder(String contentType, Callback callback,
            SoapParser parserImpl) {
        this.contentType = contentType;
        this.callback = callback;
        this.parser = parserImpl;

        this.baseContentType = getBaseContentType(contentType);
    }

    public void parse(InputStream soapStream) throws Exception {
        if (baseContentType == null) {
            throw new CodedException(X_INVALID_REQUEST,
                    "Could not get content type from request");
        }

        try {
            switch (baseContentType) {
                case TEXT_XML:
                    readSoapMessage(soapStream);
                    break;
                case MULTIPART_RELATED:
                    readMultipart(soapStream);
                    break;
                default:
                    throw new CodedException(X_INVALID_CONTENT_TYPE,
                            "Invalid content type: %s", baseContentType);
            }
        } catch (Exception e) {
            callback.onError(e);
        }

        callback.onCompleted();
    }

    private void readSoapMessage(InputStream is) throws Exception {
        log.trace("readSoapMessage");

        Soap soap = parser.parse(baseContentType, getCharset(contentType), is);
        if (soap instanceof SoapFault) {
            callback.fault((SoapFault) soap);
            return;
        }

        if (!(soap instanceof SoapMessage)) {
            log.error("Expected SoapMessage, but got: {}", soap.getXml());
            throw new CodedException(
                    X_INTERNAL_ERROR, "Unexpected SOAP message");
        }

        callback.soap((SoapMessage) soap);
    }

    private void readMultipart(InputStream is) throws Exception {
        log.trace("readMultipart");

        MimeConfig config = new MimeConfig();
        config.setHeadlessParsing(contentType);

        MimeStreamParser mimeStreamParser = new MimeStreamParser(config);
        mimeStreamParser.setContentHandler(new MultipartHandler());
        // Parse the request.
        try {
            mimeStreamParser.parse(is);
        } catch (MimeException ex) {
            // We catch the mime parsing separately because this indicates
            // invalid request from client and we want to report it as that.
            throw new CodedException(X_MIME_PARSING_FAILED, ex);
        }
    }

    private class MultipartHandler extends AbstractContentHandler {
        private Map<String, String> headers;
        private String partContentType;
        private SoapMessage soapMessage;

        @Override
        public void startHeader() throws MimeException {
            headers = new HashMap<>();
            partContentType = null;
        }

        @Override
        public void field(Field field) throws MimeException {
            if (field.getName().toLowerCase().equals(HEADER_CONTENT_TYPE)) {
                partContentType = field.getBody();
            } else {
                headers.put(field.getName().toLowerCase(), field.getBody());
            }
        }

        @Override
        public void body(BodyDescriptor bd, InputStream is)
                throws MimeException, IOException {
            if (!headers.isEmpty()) {
                log.trace("headers: {}", headers);
            }

            if (partContentType == null) {
                throw new CodedException(X_INVALID_CONTENT_TYPE,
                        "Could not get content type for part");
            }

            try {
                if (soapMessage == null) {
                    // First part, consisting of the SOAP message.
                    log.trace("Read SOAP from multipart: {}", partContentType);
                    try {
                        Soap soap = parser.parse(
                                MimeUtils.getBaseContentType(partContentType),
                                MimeUtils.getCharset(partContentType), is);
                        if (!(soap instanceof SoapMessage)) {
                            throw new CodedException(X_INTERNAL_ERROR,
                                    "Unexpected SOAP message");
                        }

                        soapMessage = (SoapMessage) soap;
                        callback.soap(soapMessage);
                    } catch (Exception e) {
                        throw translateException(e);
                    }
                } else {
                    // Attachment
                    log.trace("Read attachment from multipart: {}",
                            partContentType);
                    callback.attachment(partContentType, is, headers);
                }
            } catch (Exception ex) {
                throw translateException(ex);
            }
        }
    }
}