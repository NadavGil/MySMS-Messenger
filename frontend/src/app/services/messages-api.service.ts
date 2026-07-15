import { HttpClient, HttpErrorResponse } from '@angular/common/http';
import { Injectable } from '@angular/core';
import { Observable, MonoTypeOperatorFunction, catchError, throwError } from 'rxjs';
import { environment } from '../../environments/environment';
import { ListMessagesResponse, Message, SendMessagePayload } from '../models/message.model';
import { AuthStoreService } from './auth-store.service';

/**
 * Thin HttpClient wrapper around the Rails API (tech-design.md §8.3).
 *
 * All calls set `withCredentials: true` so the signed session cookie
 * round-trips (pairs with the backend's `credentials: true` CORS config,
 * tech-design.md §2.10). Base URL comes from environment config — never
 * hard-coded.
 *
 * CP18 (tech-design.md §13.7/§13.8): message endpoints now return `401` when
 * the identity cookie is missing/invalid/stale (session expired or the user
 * was logged out server-side). Every call here is piped through
 * `handleAuthExpiry`, which — on a 401 ONLY — tells `AuthStoreService` to
 * drop its local auth state via `clearSession()`. That flips
 * `AuthStoreService.loggedIn$`, and `AppComponent`'s state-driven `@if`
 * conditional (CP17) then swaps back to the login screen instead of leaving
 * a stuck/broken message list on screen. The original error is always
 * rethrown so callers (`NewMessageComponent`, `MessagesStoreService`) can
 * still show their own inline error state if they want to.
 */
@Injectable({ providedIn: 'root' })
export class MessagesApiService {
  // Convention: `environment.apiBaseUrl` is ONLY an origin (or '' for a
  // same-origin/reverse-proxied deploy) — it must never itself contain
  // `/api`. This service is the single place that appends the API path, so
  // all environment files stay consistent and can't silently double up the
  // `/api` segment again (see environment.production.ts comment; QA report
  // round1 M2 — production previously resolved to `/api/api/v1/messages`).
  private readonly baseUrl = `${environment.apiBaseUrl}/api/v1/messages`;

  constructor(
    private readonly http: HttpClient,
    private readonly authStore: AuthStoreService,
  ) {}

  /** POST /api/v1/messages */
  sendMessage(payload: SendMessagePayload): Observable<Message> {
    return this.http
      .post<Message>(this.baseUrl, payload, { withCredentials: true })
      .pipe(this.handleAuthExpiry());
  }

  /** GET /api/v1/messages */
  listMessages(): Observable<ListMessagesResponse> {
    return this.http
      .get<ListMessagesResponse>(this.baseUrl, { withCredentials: true })
      .pipe(this.handleAuthExpiry());
  }

  /**
   * On a `401` response, clears the auth store's session state (the
   * `AuthStoreService` is the single source of truth `AppComponent` reads
   * to decide whether to show the messenger or the login screen). Any
   * other error status passes through untouched. The error is always
   * rethrown either way — this only sets auth state as a side effect.
   */
  private handleAuthExpiry<T>(): MonoTypeOperatorFunction<T> {
    return catchError((err: unknown) => {
      if (err instanceof HttpErrorResponse && err.status === 401) {
        this.authStore.clearSession();
      }
      return throwError(() => err);
    });
  }
}
