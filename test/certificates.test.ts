/**
 * @file Tests for Certificate Authority and SSL certificate management
 */
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import { execSync } from 'child_process';
import { createCA, createCert } from 'mkcert';
import {
  generateCertificate,
  isCAInstalledInSystem,
  installCAInSystem,
  getCAPath,
  loadCertificates,
} from '../app/certificates';

// Mock external dependencies
jest.mock('mkcert');
jest.mock('fs');
jest.mock('child_process');
jest.mock('os');
jest.mock('path');

const mockCreateCA = createCA as jest.MockedFunction<typeof createCA>;
const mockCreateCert = createCert as jest.MockedFunction<typeof createCert>;
const mockFs = fs as jest.Mocked<typeof fs>;
const mockExecSync = execSync as jest.MockedFunction<typeof execSync>;
const mockOs = os as jest.Mocked<typeof os>;
const mockPath = path as jest.Mocked<typeof path>;

describe('Certificates Module', () => {
  let consoleLogSpy: jest.SpyInstance;
  let consoleErrorSpy: jest.SpyInstance;

  beforeEach(() => {
    jest.clearAllMocks();
    
    // Reset modules to clear the certificate cache
    jest.resetModules();

    // Spy on console methods
    consoleLogSpy = jest.spyOn(console, 'log').mockImplementation();
    consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation();

    // Mock os methods
    mockOs.homedir.mockReturnValue('/Users/testuser');
    mockOs.tmpdir.mockReturnValue('/tmp');

    // Mock path methods
    mockPath.join.mockImplementation((...paths: string[]) => paths.join('/'));

    // Mock process.platform as darwin by default
    Object.defineProperty(process, 'platform', {
      value: 'darwin',
      configurable: true,
    });

    // Mock process.env
    process.env.APPDATA = '/Users/testuser/AppData';
  });

  afterEach(() => {
    consoleLogSpy.mockRestore();
    consoleErrorSpy.mockRestore();
  });

  describe('getCAPath', () => {
    it('should return correct path for macOS', () => {
      Object.defineProperty(process, 'platform', {
        value: 'darwin',
        configurable: true,
      });

      const result = getCAPath();
      
      expect(mockPath.join).toHaveBeenCalledWith('/Users/testuser', 'Library', 'Application Support', 'Anglesite');
      expect(mockPath.join).toHaveBeenCalledWith('/Users/testuser/Library/Application Support/Anglesite', 'ca', 'ca.crt');
    });

    it('should return correct path for Windows', () => {
      Object.defineProperty(process, 'platform', {
        value: 'win32',
        configurable: true,
      });

      const result = getCAPath();
      
      expect(mockPath.join).toHaveBeenCalledWith('/Users/testuser/AppData', 'Anglesite');
      expect(mockPath.join).toHaveBeenCalledWith('/Users/testuser/AppData/Anglesite', 'ca', 'ca.crt');
    });

    it('should return correct path for Linux', () => {
      Object.defineProperty(process, 'platform', {
        value: 'linux',
        configurable: true,
      });

      const result = getCAPath();
      
      expect(mockPath.join).toHaveBeenCalledWith('/Users/testuser', '.config', 'anglesite');
      expect(mockPath.join).toHaveBeenCalledWith('/Users/testuser/.config/anglesite', 'ca', 'ca.crt');
    });

    it('should handle missing APPDATA on Windows', () => {
      Object.defineProperty(process, 'platform', {
        value: 'win32',
        configurable: true,
      });
      delete process.env.APPDATA;

      const result = getCAPath();
      
      expect(mockPath.join).toHaveBeenCalledWith('', 'Anglesite');
    });

    it('should handle APPDATA on Windows when defined', () => {
      Object.defineProperty(process, 'platform', {
        value: 'win32',
        configurable: true,
      });
      process.env.APPDATA = '/Windows/AppData';

      const result = getCAPath();
      
      expect(mockPath.join).toHaveBeenCalledWith('/Windows/AppData', 'Anglesite');
    });
  });

  describe('generateCertificate', () => {
    const mockCA = {
      cert: 'mock-ca-cert',
      key: 'mock-ca-key'
    };

    const mockCert = {
      cert: 'mock-cert',
      key: 'mock-key'
    };

    beforeEach(() => {
      mockCreateCA.mockResolvedValue(mockCA);
      mockCreateCert.mockResolvedValue(mockCert);
    });

    it('should generate certificate for new domains', async () => {
      // Mock CA files don't exist, so new CA will be created
      mockFs.existsSync.mockReturnValue(false);
      mockFs.mkdirSync.mockImplementation();
      mockFs.writeFileSync.mockImplementation();

      const result = await generateCertificate(['example.test']);

      expect(result).toEqual(mockCert);
      expect(mockCreateCA).toHaveBeenCalledWith({
        organization: 'Anglesite Development',
        countryCode: 'US',
        state: 'Development',
        locality: 'Local',
        validity: 825,
      });
      expect(mockCreateCert).toHaveBeenCalledWith({
        ca: mockCA,
        domains: ['example.test', 'localhost', '127.0.0.1', '::1'],
        validity: 365,
      });
      expect(consoleLogSpy).toHaveBeenCalledWith('Creating new Certificate Authority...');
      expect(consoleLogSpy).toHaveBeenCalledWith('Generating certificate for: example.test, localhost, 127.0.0.1, ::1');
      expect(consoleLogSpy).toHaveBeenCalledWith('✅ Certificate generated successfully');
    });

    it('should use existing CA when available', async () => {
      // Mock CA files exist
      mockFs.existsSync.mockReturnValue(true);
      mockFs.readFileSync.mockReturnValue('existing-ca-content');

      const result = await generateCertificate(['test.local']);

      expect(result).toEqual(mockCert);
      expect(mockCreateCA).not.toHaveBeenCalled();
      expect(mockFs.readFileSync).toHaveBeenCalledWith('/Users/testuser/Library/Application Support/Anglesite/ca/ca.crt', 'utf8');
      expect(mockFs.readFileSync).toHaveBeenCalledWith('/Users/testuser/Library/Application Support/Anglesite/ca/ca.key', 'utf8');
    });

    it('should return cached certificate for same domains', async () => {
      mockFs.existsSync.mockReturnValue(false);
      mockFs.mkdirSync.mockImplementation();
      mockFs.writeFileSync.mockImplementation();

      // Generate certificate first time
      const result1 = await generateCertificate(['example.test']);
      
      // Clear mocks but keep cache intact (don't reset modules)
      jest.clearAllMocks();
      mockCreateCert.mockResolvedValue(mockCert);
      consoleLogSpy = jest.spyOn(console, 'log').mockImplementation();
      
      // Generate certificate second time (should use cache)
      const result2 = await generateCertificate(['example.test']);

      expect(result1).toEqual(mockCert);
      expect(result2).toEqual(mockCert);
      expect(mockCreateCert).not.toHaveBeenCalled(); // Should not be called second time
      expect(consoleLogSpy).toHaveBeenCalledWith('✅ Using cached certificate for example.test');
    });

    it('should handle duplicate domains in input', async () => {
      mockFs.existsSync.mockReturnValue(false);
      mockFs.mkdirSync.mockImplementation();
      mockFs.writeFileSync.mockImplementation();

      await generateCertificate(['example.test', 'localhost', 'example.test']);

      expect(mockCreateCert).toHaveBeenCalledWith({
        ca: mockCA,
        domains: ['example.test', 'localhost', '127.0.0.1', '::1'],
        validity: 365,
      });
    });


    it('should sort domains for consistent caching', async () => {
      mockFs.existsSync.mockReturnValue(false);
      mockFs.mkdirSync.mockImplementation();
      mockFs.writeFileSync.mockImplementation();

      // Generate certificate with domains in different order
      await generateCertificate(['z.test', 'a.test']);
      
      // Clear mocks but keep cache
      jest.clearAllMocks();
      mockCreateCert.mockResolvedValue(mockCert);
      consoleLogSpy = jest.spyOn(console, 'log').mockImplementation();
      
      await generateCertificate(['a.test', 'z.test']);

      // Should not create cert second time due to caching
      expect(mockCreateCert).not.toHaveBeenCalled();
      expect(consoleLogSpy).toHaveBeenCalledWith('✅ Using cached certificate for a.test, z.test');
    });
  });

  describe('isCAInstalledInSystem', () => {
    it('should return true when CA is installed and trusted', () => {
      mockExecSync.mockReturnValue('certificate found');

      const result = isCAInstalledInSystem();

      expect(result).toBe(true);
      expect(mockExecSync).toHaveBeenCalledWith(
        'security verify-cert -c "/Users/$(whoami)/Library/Application Support/Anglesite/ca/ca.crt" 2>/dev/null || security find-certificate -c "Anglesite Development"',
        { stdio: 'pipe' }
      );
    });

    it('should return false when CA is not installed', () => {
      mockExecSync.mockImplementation(() => {
        throw new Error('Certificate not found');
      });

      const result = isCAInstalledInSystem();

      expect(result).toBe(false);
    });
  });

  describe('installCAInSystem', () => {
    const mockCA = {
      cert: 'mock-ca-cert',
      key: 'mock-ca-key'
    };

    beforeEach(() => {
      mockCreateCA.mockResolvedValue(mockCA);
      mockFs.writeFileSync.mockImplementation();
      mockFs.unlinkSync.mockImplementation();
      mockExecSync.mockReturnValue('success');
    });

    it('should install CA successfully with existing CA', async () => {
      mockFs.existsSync.mockReturnValue(true);
      mockFs.readFileSync.mockReturnValue('existing-ca-cert');

      const result = await installCAInSystem();

      expect(result).toBe(true);
      expect(mockFs.writeFileSync).toHaveBeenCalledWith('/tmp/anglesite-ca.crt', 'existing-ca-cert');
      expect(mockExecSync).toHaveBeenCalledWith(
        'security add-trusted-cert -d -r trustRoot "/tmp/anglesite-ca.crt"',
        { stdio: 'pipe' }
      );
      expect(mockFs.unlinkSync).toHaveBeenCalledWith('/tmp/anglesite-ca.crt');
      expect(consoleLogSpy).toHaveBeenCalledWith('✅ Anglesite CA installed in user keychain');
    });

    it('should install CA successfully with new CA', async () => {
      mockFs.existsSync.mockReturnValue(false);
      mockFs.mkdirSync.mockImplementation();

      const result = await installCAInSystem();

      expect(result).toBe(true);
      expect(mockCreateCA).toHaveBeenCalled();
      expect(mockFs.writeFileSync).toHaveBeenCalledWith('/tmp/anglesite-ca.crt', mockCA.cert);
    });

    it('should handle security command failure', async () => {
      mockFs.existsSync.mockReturnValue(true);
      mockFs.readFileSync.mockReturnValue('existing-ca-cert');
      mockExecSync.mockImplementation(() => {
        throw new Error('security command failed');
      });

      const result = await installCAInSystem();

      expect(result).toBe(false);
      expect(consoleErrorSpy).toHaveBeenCalledWith('Failed to install CA in keychain:', expect.any(Error));
    });

    it('should handle CA creation failure', async () => {
      mockFs.existsSync.mockReturnValue(false);
      mockCreateCA.mockRejectedValue(new Error('CA creation failed'));

      const result = await installCAInSystem();

      expect(result).toBe(false);
      expect(consoleErrorSpy).toHaveBeenCalledWith('Failed to install CA in keychain:', expect.any(Error));
    });

    it('should not clean up temp file when security command fails', async () => {
      mockFs.existsSync.mockReturnValue(true);
      mockFs.readFileSync.mockReturnValue('existing-ca-cert');
      
      // Mock execSync to throw on the security command
      mockExecSync.mockImplementation(() => {
        throw new Error('security command failed');
      });

      const result = await installCAInSystem();

      expect(result).toBe(false);
      expect(mockFs.writeFileSync).toHaveBeenCalledWith('/tmp/anglesite-ca.crt', 'existing-ca-cert');
      // File should NOT be cleaned up on error (per the actual code)
      expect(mockFs.unlinkSync).not.toHaveBeenCalled();
    });
  });

  describe('loadCertificates', () => {
    const mockCert = {
      cert: 'mock-cert',
      key: 'mock-key'
    };

    beforeEach(() => {
      mockCreateCA.mockResolvedValue({ cert: 'ca-cert', key: 'ca-key' });
      mockCreateCert.mockResolvedValue(mockCert);
      mockFs.existsSync.mockReturnValue(false);
      mockFs.mkdirSync.mockImplementation();
      mockFs.writeFileSync.mockImplementation();
    });

    it('should load certificates with default domains', async () => {
      const result = await loadCertificates();

      expect(result).toEqual(mockCert);
      expect(mockCreateCert).toHaveBeenCalledWith({
        ca: { cert: 'ca-cert', key: 'ca-key' },
        domains: ['anglesite.test', 'localhost', '127.0.0.1', '::1'],
        validity: 365,
      });
    });

    it('should load certificates with custom domains', async () => {
      const customDomains = ['custom.test', 'another.test'];
      
      const result = await loadCertificates(customDomains);

      expect(result).toEqual(mockCert);
      expect(mockCreateCert).toHaveBeenCalledWith({
        ca: { cert: 'ca-cert', key: 'ca-key' },
        domains: ['another.test', 'custom.test', 'localhost', '127.0.0.1', '::1'], // domains are sorted
        validity: 365,
      });
    });
  });
});