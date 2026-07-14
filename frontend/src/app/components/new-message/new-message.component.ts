import { CommonModule } from '@angular/common';
import { Component } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { MessagesApiService } from '../../services/messages-api.service';
import { MessagesStoreService } from '../../services/messages-store.service';

const BODY_MAX_LENGTH = 250;

interface NewMessageForm {
  toNumber: FormControl<string>;
  body: FormControl<string>;
}

/**
 * "New Message" panel (tech-design.md §8.4).
 *
 * Reactive form: phone number input + message textarea with a live
 * `N/250` counter, a Clear link that resets the form, and a Submit button
 * disabled while the form is invalid/empty. On submit, calls
 * `MessagesApiService.sendMessage()`; on success the form is cleared and
 * the history store is told to refresh; on failure an inline error shows.
 */
@Component({
  selector: 'app-new-message',
  standalone: true,
  imports: [CommonModule, ReactiveFormsModule],
  templateUrl: './new-message.component.html',
  styleUrl: './new-message.component.css',
})
export class NewMessageComponent {
  readonly bodyMaxLength = BODY_MAX_LENGTH;

  readonly form = new FormGroup<NewMessageForm>({
    toNumber: new FormControl('', {
      nonNullable: true,
      validators: [Validators.required, Validators.pattern(/^\+[1-9]\d{1,14}$/)],
    }),
    body: new FormControl('', {
      nonNullable: true,
      validators: [Validators.required, Validators.maxLength(BODY_MAX_LENGTH)],
    }),
  });

  submitting = false;
  errorMessage: string | null = null;

  constructor(
    private readonly api: MessagesApiService,
    private readonly store: MessagesStoreService,
  ) {}

  get bodyLength(): number {
    return this.form.controls.body.value?.length ?? 0;
  }

  onSubmit(): void {
    if (this.form.invalid || this.submitting) {
      return;
    }

    this.submitting = true;
    this.errorMessage = null;

    const { toNumber, body } = this.form.getRawValue();

    this.api.sendMessage({ to_number: toNumber, body }).subscribe({
      next: () => {
        this.submitting = false;
        this.onClear();
        this.store.refresh();
      },
      error: (err) => {
        this.submitting = false;
        this.errorMessage = this.extractErrorMessage(err);
      },
    });
  }

  onClear(): void {
    this.form.reset({ toNumber: '', body: '' });
    this.errorMessage = null;
  }

  private extractErrorMessage(err: unknown): string {
    const httpError = err as { error?: { errors?: Record<string, string[]> } };
    const errors = httpError?.error?.errors;
    if (errors) {
      return Object.values(errors).flat().join(' ');
    }
    return 'Failed to send message. Please try again.';
  }
}
