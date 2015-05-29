package ee.ria.xroad_legacy.common.util;

public interface StartStop {
    void start() throws Exception;

    void stop() throws Exception;

    void join() throws InterruptedException;
}