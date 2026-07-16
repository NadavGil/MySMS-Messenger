import { CommonModule } from '@angular/common';
import { Component, OnInit } from '@angular/core';
import { Observable } from 'rxjs';
import { Message, MessageStatus } from '../../models/message.model';
import { MessagesStoreService } from '../../services/messages-store.service';
import { UtcTimestampPipe } from '../../pipes/utc-timestamp.pipe';
import { codepointLength } from '../../utils/text-length.util';

const BODY_MAX_LENGTH = 250;

// Bug blitz (2026-07-16) fix: closes the literal Bonus 3 requirement from
// the original exercise spec ("Add a reflection to the message cards
// showing that twilio successfully delivered the message") — the backend
// webhook has updated `status` in the DB since Bonus 3 landed, and
// MessagesController#serialize already returned it on every
// GET /api/v1/messages, but the frontend never rendered it anywhere. Human
// labels + a CSS status class per value (message-history.component.css).
const STATUS_LABELS: Record<MessageStatus, string> = {
  queued: 'Queued',
  sent: 'Sent',
  delivered: 'Delivered',
  undelivered: 'Undelivered',
  failed: 'Failed',
};

/**
 * "Message History (N)" panel (tech-design.md §8.4).
 *
 * Subscribes to `MessagesStoreService` (RxJS `BehaviorSubject` store, §8.5)
 * and triggers the initial fetch via `refresh()` on init. Renders a
 * scrollable list of message cards, each showing the destination number,
 * a formatted UTC timestamp, the body in a bordered box, and a per-message
 * `N/250` count — plus loading / empty / error states.
 */
@Component({
  selector: 'app-message-history',
  standalone: true,
  imports: [CommonModule, UtcTimestampPipe],
  templateUrl: './message-history.component.html',
  styleUrl: './message-history.component.css',
})
export class MessageHistoryComponent implements OnInit {
  readonly bodyMaxLength = BODY_MAX_LENGTH;

  readonly messages$: Observable<Message[]>;
  readonly count$: Observable<number>;
  readonly loading$: Observable<boolean>;
  readonly error$: Observable<string | null>;

  constructor(private readonly store: MessagesStoreService) {
    this.messages$ = this.store.messages$;
    this.count$ = this.store.count$;
    this.loading$ = this.store.loading$;
    this.error$ = this.store.error$;
  }

  ngOnInit(): void {
    this.store.refresh();
  }

  trackById(_index: number, message: Message): string {
    return message.id;
  }

  /**
   * Unicode codepoint count for a message body (not UTF-16 `.length`) so the
   * per-message count agrees with the New Message form's counter/validator
   * and with the eventual backend Ruby `String#length` validation (QA
   * report round1 N1).
   */
  bodyLength(body: string): number {
    return codepointLength(body);
  }

  /** Human-readable label for a message's delivery status. */
  statusLabel(status: MessageStatus): string {
    return STATUS_LABELS[status] ?? status;
  }

  /** CSS modifier class for a message's delivery status (color-coding). */
  statusClass(status: MessageStatus): string {
    return `status-${status}`;
  }
}
