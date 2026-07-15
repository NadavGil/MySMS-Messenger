import { Injectable } from '@angular/core';
import { BehaviorSubject, Observable, Subject, catchError, map, of, switchMap, tap } from 'rxjs';
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

  // QA report round1 M4: refresh() used to start a brand-new one-off
  // `.subscribe()` per call with no cancellation, so if two refreshes
  // overlapped (e.g. fast double-submit, or a send completing while the
  // initial load is still in-flight) a stale, slower response could arrive
  // after and overwrite a newer one. `refreshTrigger$` + `switchMap` fixes
  // this: each new refresh() call cancels/ignores any still-in-flight
  // previous GET, so only the latest request's response can ever reach the
  // store.
  private readonly refreshTrigger$ = new Subject<void>();

  readonly messages$: Observable<Message[]> = this.messagesSubject.asObservable();
  readonly count$: Observable<number> = this.messages$.pipe(map((messages) => messages.length));
  readonly loading$: Observable<boolean> = this.loadingSubject.asObservable();
  readonly error$: Observable<string | null> = this.errorSubject.asObservable();

  constructor(private readonly api: MessagesApiService) {
    this.refreshTrigger$
      .pipe(
        switchMap(() => {
          this.loadingSubject.next(true);
          this.errorSubject.next(null);
          return this.api.listMessages().pipe(
            tap((response) => {
              this.messagesSubject.next(response.messages);
              this.loadingSubject.next(false);
            }),
            catchError(() => {
              this.errorSubject.next('Failed to load message history. Please try again.');
              this.loadingSubject.next(false);
              return of(null);
            }),
          );
        }),
      )
      .subscribe();
  }

  /**
   * Re-fetches the history list from the server. Safe to call multiple
   * times in quick succession — `switchMap` above cancels any in-flight
   * request from a previous call, so only the response to the most recent
   * `refresh()` can ever update the store (QA report round1 M4).
   */
  refresh(): void {
    this.refreshTrigger$.next();
  }

  /**
   * Bug blitz (2026-07-15) finding: this store is `providedIn: 'root'`, so
   * it outlives any single user's session — nothing was resetting it on
   * logout. On a shared/kiosk machine, User B logging in right after User A
   * logs out would briefly see User A's stale message count in the
   * `<h2>Message History (N)</h2>` header (that count is NOT gated behind
   * the `loading$`/`error$` conditional in the template, unlike the message
   * list itself) until the next `refresh()` call resolved and overwrote it.
   * `AppComponent` now subscribes to `AuthStoreService.loggedIn$` and calls
   * this whenever it goes `false` (covers both the explicit logout button
   * and the automatic 401 `clearSession()` path) — done at the component
   * level rather than inside `AuthStoreService` itself, to avoid a circular
   * DI dependency (`AuthStoreService` → `MessagesStoreService` →
   * `MessagesApiService` → `AuthStoreService`).
   */
  clear(): void {
    this.messagesSubject.next([]);
    this.errorSubject.next(null);
    this.loadingSubject.next(false);
  }
}
