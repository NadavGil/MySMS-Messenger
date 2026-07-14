import { FormControl } from '@angular/forms';
import { codepointLength, maxCodepointLength } from './text-length.util';

describe('codepointLength', () => {
  it('matches raw .length for plain ASCII', () => {
    expect(codepointLength('hello')).toBe(5);
    expect('hello'.length).toBe(5);
  });

  it('counts a surrogate-pair emoji as 1 codepoint, not 2 UTF-16 units', () => {
    const emoji = '🎉';
    expect(emoji.length).toBe(2); // UTF-16 code units
    expect(codepointLength(emoji)).toBe(1); // Unicode codepoints
  });

  it('counts a mixed string of text and emoji correctly', () => {
    const text = 'hi 🎉🎉🎉';
    expect(text.length).toBe(9);
    expect(codepointLength(text)).toBe(6);
  });

  it('returns 0 for an empty string', () => {
    expect(codepointLength('')).toBe(0);
  });
});

describe('maxCodepointLength validator', () => {
  it('passes when codepoint count is within the limit, even if UTF-16 length exceeds it', () => {
    const control = new FormControl('🎉'.repeat(150)); // 150 codepoints, 300 UTF-16 units
    const result = maxCodepointLength(250)(control);
    expect(result).toBeNull();
  });

  it('fails when codepoint count exceeds the limit', () => {
    const control = new FormControl('🎉'.repeat(251));
    const result = maxCodepointLength(250)(control);
    expect(result).toEqual({ maxlength: { requiredLength: 250, actualLength: 251 } });
  });

  it('returns null for an empty/null value (required validator handles emptiness separately)', () => {
    expect(maxCodepointLength(250)(new FormControl(''))).toBeNull();
    expect(maxCodepointLength(250)(new FormControl(null))).toBeNull();
  });
});
