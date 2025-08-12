/**
 * @file Tests for HTTPS proxy server management
 */
import * as https from 'https';
import * as http from 'http';
import { createHttpsProxy, stopHttpsProxy, restartHttpsProxy } from '../../app/server/https-proxy';

// Mock the certificates module
jest.mock('../../app/certificates', () => ({
  loadCertificates: jest.fn(),
}));

// Mock Node.js modules
jest.mock('https');
jest.mock('http');

const mockHttps = https as jest.Mocked<typeof https>;
const mockHttp = http as jest.Mocked<typeof http>;
const { loadCertificates } = require('../../app/certificates');

describe('HTTPS Proxy Server', () => {
  let mockServer: any;
  let mockProxyReq: any;
  let mockProxyRes: any;
  let consoleLogSpy: jest.SpyInstance;
  let consoleErrorSpy: jest.SpyInstance;

  beforeEach(() => {
    jest.clearAllMocks();

    // Spy on console methods
    consoleLogSpy = jest.spyOn(console, 'log').mockImplementation();
    consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation();

    // Mock server object
    mockServer = {
      listen: jest.fn(),
      close: jest.fn(),
      on: jest.fn(),
    };

    // Mock proxy request object
    mockProxyReq = {
      on: jest.fn(),
      pipe: jest.fn(),
    };

    // Mock proxy response object
    mockProxyRes = {
      statusCode: 200,
      headers: { 'content-type': 'text/html' },
      pipe: jest.fn(),
    };

    // Setup default mocks
    mockHttps.createServer.mockReturnValue(mockServer as any);
    mockHttp.request.mockReturnValue(mockProxyReq as any);

    loadCertificates.mockResolvedValue({
      cert: 'mock-cert',
      key: 'mock-key',
    });
  });

  afterEach(() => {
    consoleLogSpy.mockRestore();
    consoleErrorSpy.mockRestore();
  });

  describe('createHttpsProxy', () => {
    it('should create and start HTTPS proxy successfully', async () => {
      // Mock successful server listen
      mockServer.listen.mockImplementation((port: number, host: string, callback: () => void) => {
        setTimeout(callback, 0);
      });

      const result = await createHttpsProxy(8080, 3000, 'test.com');

      expect(result).toBe(true);
      expect(loadCertificates).toHaveBeenCalledWith(['test.com']);
      expect(mockHttps.createServer).toHaveBeenCalledWith({ cert: 'mock-cert', key: 'mock-key' }, expect.any(Function));
      expect(mockServer.listen).toHaveBeenCalledWith(8080, '0.0.0.0', expect.any(Function));
      expect(consoleLogSpy).toHaveBeenCalledWith('Creating HTTPS proxy for test.com on port 8080 -> 3000');
      expect(consoleLogSpy).toHaveBeenCalledWith('✅ HTTPS proxy server running at https://test.com:8080/');
    });

    it('should use default hostname when not provided', async () => {
      mockServer.listen.mockImplementation((port: number, host: string, callback: () => void) => {
        setTimeout(callback, 0);
      });

      const result = await createHttpsProxy(8080, 3000);

      expect(result).toBe(true);
      expect(loadCertificates).toHaveBeenCalledWith(['localhost']);
      expect(consoleLogSpy).toHaveBeenCalledWith('Creating HTTPS proxy for localhost on port 8080 -> 3000');
    });

    it('should handle server listen error', async () => {
      const error = new Error('Port already in use');
      mockServer.on.mockImplementation((event: string, callback: (err: Error) => void) => {
        if (event === 'error') {
          setTimeout(() => callback(error), 0);
        }
      });

      const result = await createHttpsProxy(8080, 3000);

      expect(result).toBe(false);
      expect(consoleErrorSpy).toHaveBeenCalledWith('❌ HTTPS proxy server error:', error);
    });

    it('should handle certificate loading error', async () => {
      const error = new Error('Certificate not found');
      loadCertificates.mockRejectedValue(error);

      const result = await createHttpsProxy(8080, 3000);

      expect(result).toBe(false);
      expect(consoleErrorSpy).toHaveBeenCalledWith('❌ Failed to start HTTPS proxy:', error);
      expect(consoleLogSpy).toHaveBeenCalledWith('Continuing with HTTP-only mode');
    });

    it('should handle proxy requests correctly', async () => {
      let requestHandler: any;

      mockHttps.createServer.mockImplementation((options, handler) => {
        requestHandler = handler;
        return mockServer as any;
      });

      mockServer.listen.mockImplementation((port: number, host: string, callback: () => void) => {
        setTimeout(callback, 0);
      });

      await createHttpsProxy(8080, 3000, 'test.com');

      // Simulate incoming request
      const mockReq = {
        method: 'GET',
        url: '/test',
        headers: { host: 'test.com', 'user-agent': 'test' },
        pipe: jest.fn(),
      };

      const mockRes = {
        writeHead: jest.fn(),
        end: jest.fn(),
      };

      // Mock http.request callback
      mockHttp.request.mockImplementation((options, callback) => {
        setTimeout(() => (callback as any)(mockProxyRes), 0);
        return mockProxyReq as any;
      });

      // Call the request handler
      requestHandler(mockReq, mockRes);

      // Wait for async operations
      await new Promise((resolve) => setTimeout(resolve, 10));

      expect(mockHttp.request).toHaveBeenCalledWith(
        {
          hostname: 'localhost',
          port: 3000,
          path: '/test',
          method: 'GET',
          headers: mockReq.headers,
        },
        expect.any(Function)
      );

      expect(consoleLogSpy).toHaveBeenCalledWith('HTTPS proxy request: GET /test from test.com');
      expect(consoleLogSpy).toHaveBeenCalledWith('Proxy response: 200 for /test');
      expect(mockRes.writeHead).toHaveBeenCalledWith(200, mockProxyRes.headers);
      expect(mockProxyRes.pipe).toHaveBeenCalledWith(mockRes);
      expect(mockReq.pipe).toHaveBeenCalledWith(mockProxyReq);
    });

    it('should handle proxy request errors', async () => {
      let requestHandler: any;

      mockHttps.createServer.mockImplementation((options, handler) => {
        requestHandler = handler;
        return mockServer as any;
      });

      mockServer.listen.mockImplementation((port: number, host: string, callback: () => void) => {
        setTimeout(callback, 0);
      });

      await createHttpsProxy(8080, 3000);

      const mockReq = {
        method: 'GET',
        url: '/test',
        headers: { host: 'localhost' },
        pipe: jest.fn(),
      };

      const mockRes = {
        writeHead: jest.fn(),
        end: jest.fn(),
      };

      // Mock error in proxy request
      mockProxyReq.on.mockImplementation((event: string, callback: (err: Error) => void) => {
        if (event === 'error') {
          setTimeout(() => callback(new Error('Connection refused')), 0);
        }
      });

      requestHandler(mockReq, mockRes);

      // Wait for async operations
      await new Promise((resolve) => setTimeout(resolve, 10));

      expect(consoleErrorSpy).toHaveBeenCalledWith('HTTPS proxy request error:', expect.any(Error));
      expect(mockRes.writeHead).toHaveBeenCalledWith(500);
      expect(mockRes.end).toHaveBeenCalledWith('Proxy error');
    });

    it('should handle undefined status code in proxy response', async () => {
      let requestHandler: any;

      mockHttps.createServer.mockImplementation((options, handler) => {
        requestHandler = handler;
        return mockServer as any;
      });

      mockServer.listen.mockImplementation((port: number, host: string, callback: () => void) => {
        setTimeout(callback, 0);
      });

      await createHttpsProxy(8080, 3000);

      const mockReq = {
        method: 'GET',
        url: '/test',
        headers: { host: 'localhost' },
        pipe: jest.fn(),
      };

      const mockRes = {
        writeHead: jest.fn(),
        end: jest.fn(),
      };

      // Mock proxy response with undefined status code
      const mockProxyResUndefined = {
        statusCode: undefined,
        headers: { 'content-type': 'text/html' },
        pipe: jest.fn(),
      };

      mockHttp.request.mockImplementation((options, callback) => {
        setTimeout(() => (callback as any)(mockProxyResUndefined), 0);
        return mockProxyReq as any;
      });

      requestHandler(mockReq, mockRes);

      // Wait for async operations
      await new Promise((resolve) => setTimeout(resolve, 10));

      expect(mockRes.writeHead).toHaveBeenCalledWith(500, mockProxyResUndefined.headers);
    });
  });

  describe('stopHttpsProxy', () => {
    it('should stop running proxy server', async () => {
      // First create a proxy to have a server to stop
      mockServer.listen.mockImplementation((port: number, host: string, callback: () => void) => {
        setTimeout(callback, 0);
      });

      // Create a proxy server first
      await createHttpsProxy(8080, 3000);

      // Now stop it
      stopHttpsProxy();

      expect(consoleLogSpy).toHaveBeenCalledWith('Stopping HTTPS proxy server');
      expect(mockServer.close).toHaveBeenCalled();
    });

    it('should handle stopping when no server is running', () => {
      stopHttpsProxy();

      // Should not throw error and not attempt to close
      expect(mockServer.close).not.toHaveBeenCalled();
    });
  });

  describe('restartHttpsProxy', () => {
    it('should restart proxy with new configuration', async () => {
      // Mock successful server creation and listening
      mockServer.listen.mockImplementation((port: number, host: string, callback: () => void) => {
        setTimeout(callback, 0);
      });

      const result = await restartHttpsProxy(8443, 4000, 'newhost.com');

      expect(result).toBe(true);
      expect(consoleLogSpy).toHaveBeenCalledWith('Restarting HTTPS proxy server for new website...');
      expect(loadCertificates).toHaveBeenCalledWith(['newhost.com']);
      expect(mockServer.listen).toHaveBeenCalledWith(8443, '0.0.0.0', expect.any(Function));
    });

    it('should handle restart failure', async () => {
      const error = new Error('Restart failed');
      loadCertificates.mockRejectedValue(error);

      const result = await restartHttpsProxy(8443, 4000, 'newhost.com');

      expect(result).toBe(false);
      expect(consoleLogSpy).toHaveBeenCalledWith('Restarting HTTPS proxy server for new website...');
      expect(consoleErrorSpy).toHaveBeenCalledWith('❌ Failed to start HTTPS proxy:', error);
    });
  });
});
