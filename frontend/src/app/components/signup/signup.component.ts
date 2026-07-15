import { CommonModule } from '@angular/common';
import { Component, EventEmitter, Output } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { AuthStoreService } from '../../services/auth-store.service';

interface SignupForm {
  username: FormControl<string>;
  password: FormControl<string>;
}

/**
 * Signup form (tech-design.md §13.2/§13.7).
 *
 * Client-side validators mirror (but don't replace) the server's `User`
 * model rules: username 3-30 chars, lowercase letters/digits/underscore
 * only (server normalizes case, so we don't force-lowercase client-side —
 * server 422 errors are surfaced verbatim on mismatch); password minimum 8
 * chars. Same disabled-Submit-while-invalid / inline-error conventions as
 * `NewMessageComponent` and `LoginComponent`.
 */
@Component({
  selector: 'app-signup',
  standalone: true,
  imports: [CommonModule, ReactiveFormsModule],
  templateUrl: './signup.component.html',
  styleUrl: './signup.component.css',
})
export class SignupComponent {
  readonly form = new FormGroup<SignupForm>({
    username: new FormControl('', {
      nonNullable: true,
      validators: [Validators.required, Validators.pattern(/^[a-zA-Z0-9_]{3,30}$/)],
    }),
    password: new FormControl('', {
      nonNullable: true,
      validators: [Validators.required, Validators.minLength(8)],
    }),
  });

  submitting = false;
  errorMessage: string | null = null;

  /** Emitted when the user clicks "Log in instead" to switch panels. */
  @Output() readonly switchToLogin = new EventEmitter<void>();

  constructor(private readonly authStore: AuthStoreService) {}

  onSubmit(): void {
    if (this.form.invalid || this.submitting) {
      return;
    }

    this.submitting = true;
    this.errorMessage = null;

    const { username, password } = this.form.getRawValue();

    this.authStore.signup({ username, password }).subscribe({
      next: () => {
        this.submitting = false;
      },
      error: (err) => {
        this.submitting = false;
        this.errorMessage = this.extractErrorMessage(err);
      },
    });
  }

  private extractErrorMessage(err: unknown): string {
    const httpError = err as { error?: { errors?: Record<string, string[]> } };
    const errors = httpError?.error?.errors;
    if (errors) {
      return Object.values(errors).flat().join(' ');
    }
    return 'Failed to sign up. Please try again.';
  }
}
