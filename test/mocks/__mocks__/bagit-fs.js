// Mock for bagit-fs
function MockBagItFs() {
  return {
    createWriteStream: jest.fn(() => ({
      on: jest.fn(),
      write: jest.fn(),
      end: jest.fn(),
    })),
    mkdir: jest.fn((path, callback) => callback && callback()),
    finalize: jest.fn((callback) => callback && callback()),
  };
}

module.exports = MockBagItFs;
