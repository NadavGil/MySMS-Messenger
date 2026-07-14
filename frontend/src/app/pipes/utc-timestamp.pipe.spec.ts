import { UtcTimestampPipe } from './utc-timestamp.pipe';

describe('UtcTimestampPipe', () => {
  const pipe = new UtcTimestampPipe();

  it('formats the wireframe example correctly', () => {
    // 2020-05-17 is a Sunday.
    expect(pipe.transform('2020-05-17T11:18:45Z')).toBe('Sunday, 17-May-20 11:18:45 UTC');
  });

  it('pads single-digit day/hour/minute/second components', () => {
    // 2020-05-03 is a Sunday; use a time with single-digit components.
    expect(pipe.transform('2020-05-03T01:02:03Z')).toBe('Sunday, 03-May-20 01:02:03 UTC');
  });

  it('returns an empty string for null/undefined/invalid input', () => {
    expect(pipe.transform(null)).toBe('');
    expect(pipe.transform(undefined)).toBe('');
    expect(pipe.transform('not-a-date')).toBe('');
  });
});
