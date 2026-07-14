import { Injectable } from '@angular/core';
import { BehaviorSubject, Observable, catchError, map, of, tap } from 'rxjs';
import { Message } from '../models/message.model';
import { MessagesApiService } from './messages-api.service';

/**
 * Simple RxJS `BehaviorSubject` store (tech-design.md §8.5).
 *
 * Explicitly NOT NgRx — two panels don't warrant it (locked decision, §0).
 * `NewMessageComponent` calls `refresh()` after a successful send; server is
 * the source of truth (no optimistic append, per HLD §9 open question).
 */
@Injectable({ providedIn: 'root' })
export class MessagesStoreService {
  private readonly messagesSubject = new BehaviorSubject<Message[]>([]);
  private readonly loadingSubject = new BehaviorSubject<boolean>(false);
  private readonly errorSubject = new BehaviorSubject<string | null>(null);

  readonly messages$: Observable<Message[]> = this.messagesSubject.asObservable();
  readonly count$: Observable<number> = this.messages$.pipe(map((messages) => messages.length));
  readonly loading$: Observable<boolean> = this.loadingSubject.asObservable();
  readonly error$: Observable<string | null> = this.errorSubject.asObservable();

  constructor(private readonly api: MessagesApiService) {}

  /** Re-fetches the history list from the server. */
  refresh(): void {
    this.loadingSubject.next(true);
    this.errorSubject.next(null);
    this.api
      .listMessages()
      .pipe(
        tap((response) => {
          this.messagesSubject.next(response.messages);
          this.loadingSubject.next(false);
        }),
        catchError((err) => {
          this.errorSubject.next('Failed to load message history. Please try again.');
          this.loadingSubject.next(false);
          return of(null);
        }),
      )
      .subscribe();
  }
}
