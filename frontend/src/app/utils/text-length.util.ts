import { AbstractControl, ValidationErrors, ValidatorFn } from '@angular/forms';

/**
 * Counts Unicode CODEPOINTS in `text`, not UTF-16 code units.
 *
 * QA report round1 (N1): JS string `.length` counts UTF-16 code units, so a
 * single astral-plane emoji (e.g. many 👍/🎉 characters, which are encoded
 * as a UTF-16 surrogate pair) counts as 2 with `.length` but is 1 codepoint.
 * `Array.from(text).length` / `[...text]` iterate by codepoint, matching
 * Ruby's `String#length` (which counts Unicode codepoints) far more closely
 * than raw `.length` does — so the frontend counter and the future backend
 * 250-char validation (tech-design.md §6.1) will agree on the same string.
 *
 * NOTE: this is codepoint-accurate, not grapheme-cluster-accurate — a
 * combining-mark sequence or a ZWJ emoji (e.g. a family emoji built from
 * several base emoji + zero-width joiners) is still multiple codepoints and
 * will count as more than "1 visual character". True grapheme-cluster
 * counting (e.g. via `Intl.Segmenter`) is out of scope per QA report N1;
 * codepoint counting is the agreed frontend/backend convention.
 *
 * IMPORTANT: if/when backend validation lands (SendMessageService /
 * tech-design §6.1), it must validate on Ruby `String#length` (codepoints),
 * NOT `bytesize` (UTF-8 byte length) and NOT a grapheme-cluster library —
 * to stay consistent with this frontend count.
 */
export function codepointLength(text: string): number {
  return Array.from(text).length;
}

/**
 * Reactive Forms validator equivalent to `Validators.maxLength`, but counting
 * Unicode codepoints (see `codepointLength`) instead of UTF-16 code units.
 * Produces the same `{ maxlength: { requiredLength, actualLength } }` error
 * shape as Angular's built-in `Validators.maxLength` for drop-in
 * compatibility with existing error-display code/tests.
 */
export function maxCodepointLength(maxLength: number): ValidatorFn {
  return (control: AbstractControl): ValidationErrors | null => {
    const value: string | null | undefined = control.value;
    if (value == null || value === '') {
      return null;
    }
    const actualLength = codepointLength(value);
    return actualLength > maxLength
      ? { maxlength: { requiredLength: maxLength, actualLength } }
      : null;
  };
}
