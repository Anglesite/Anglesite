// Mock for @11ty/eleventy-dev-server
class MockEleventyDevServer {
  constructor() {
    this.watcher = {
      on: jest.fn(),
      close: jest.fn(),
    };
  }

  async serve() {
    return Promise.resolve();
  }

  async close() {
    return Promise.resolve();
  }

  watchFiles() {
    return this;
  }
}

module.exports = MockEleventyDevServer;
