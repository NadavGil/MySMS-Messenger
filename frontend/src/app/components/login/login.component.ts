import { CommonModule } from '@angular/common';
import { Component, EventEmitter, Output } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { AuthStoreService } from '../../services/auth-store.service';

interface LoginForm {
  username: FormControl<string>;
  password: FormControl<string>;
}

/**
 * Login form (tech-design.md §13.7/§13.8 CP17).
 *
 * Reactive form, same conventions as `NewMessageComponent`: disabled Submit
 * while invalid/submitting, inline error display on failure. On success the
 * `AuthStoreService` picks up the returned user, and `AppComponent`'s
 * state-driven conditional swaps to the messenger UI.
 */
@Component({
  selector: 'app-login',
  standalone: true,
  imports: [CommonModule, ReactiveFormsModule],
  templateUrl: './login.component.html',
  styleUrl: './login.component.css',
})
export class LoginComponent {
  readonly form = new FormGroup<LoginForm>({
    username: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    password: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
  });

  submitting = false;
  errorMessage: string | null = null;

  /** Emitted when the user clicks "Sign up instead" to switch panels. */
  @Output() readonly switchToSignup = new EventEmitter<void>();

  constructor(private readonly authStore: AuthStoreService) {}

  onSubmit(): void {
    if (this.form.invalid || this.submitting) {
      return;
    }

    this.submitting = true;
    this.errorMessage = null;

    const { username, password } = this.form.getRawValue();

    this.authStore.login({ username, password }).subscribe({
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
    return 'Failed to log in. Please try again.';
  }
}
