/**
 * Type definitions for bagit-fs package
 * A Node.js fs implementation for BagIt format
 */

declare module 'bagit-fs' {
  import { Writable } from 'stream';
  interface BagOptions {
    [key: string]: string;
  }

  interface ManifestEntry {
    name: string;
    hash: string;
  }

  interface Stats {
    isFile(): boolean;
    isDirectory(): boolean;
    size: number;
    mtime: Date;
  }

  interface BagItBag {
    createWriteStream(path: string): Writable;
    finalize(callback: () => void): void;
    readFile(name: string, callback: (err: Error | null, data: Buffer) => void): void;
    readFile(name: string, opts: Record<string, unknown>, callback: (err: Error | null, data: Buffer) => void): void;
    readManifest(callback: (err: Error | null, manifest: ManifestEntry[]) => void): void;
    getManifestEntry(name: string, callback: (err: Error | null, entry: ManifestEntry | null) => void): void;
    mkdir(path: string, callback?: (err: Error | null) => void): void;
    stat(path: string, callback: (err: Error | null, stats: Stats) => void): void;
    readdir(path: string, callback: (err: Error | null, files: string[]) => void): void;
    unlink(path: string, callback?: (err: Error | null) => void): void;
    rmdir(path: string, callback?: (err: Error | null) => void): void;
  }

  function BagIt(destination: string, algorithm?: string, metadata?: BagOptions): BagItBag;

  export default BagIt;
}
