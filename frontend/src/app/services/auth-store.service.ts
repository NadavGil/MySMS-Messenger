import { Injectable } from '@angular/core';
import { BehaviorSubject, Observable, catchError, finalize, map, of, tap } from 'rxjs';
import { AuthUser, LoginPayload, SignupPayload } from '../models/auth.model';
import { AuthApiService } from './auth-api.service';

/**
 * Simple RxJS `BehaviorSubject` store for auth state — mirrors
 * `MessagesStoreService`'s style (tech-design.md §8.5), just as explicitly
 * NOT NgRx.
 *
 * Because identity now lives in a signed HttpOnly `:msms_owner` cookie
 * (tech-design.md §13.1/§13.3), JS can never read it directly. `checkSession()`
 * (called once on app init, see `AppComponent`) is the ONLY way to learn
 * whether a previously-issued cookie is still valid after a page refresh —
 * it calls `GET /api/v1/auth/me` and treats any error (401 "Not
 * authenticated", or network failure) as "logged out" rather than surfacing
 * it as a hard error, since an anonymous visitor hitting `me` is the
 * expected/common case, not a failure.
 *
 * `clearSession()` is called by `MessagesApiService`/store (CP18) whenever a
 * message-endpoint call comes back 401, so an expired/invalidated session
 * kicks the user back to the login screen instead of leaving a stuck UI.
 */
@Injectable({ providedIn: 'root' })
export class AuthStoreService {
  private readonly userSubject = new BehaviorSubject<AuthUser | null>(null);
  private readonly loadingSubject = new BehaviorSubject<boolean>(false);
  private readonly errorSubject = new BehaviorSubject<string | null>(null);
  // True once the initial checkSession() (app boot) has resolved, so the
  // shell can avoid flashing the login screen before we know whether a
  // session cookie is still valid.
  private readonly checkedSubject = new BehaviorSubject<boolean>(false);

  readonly user$: Observable<AuthUser | null> = this.userSubject.asObservable();
  readonly loggedIn$: Observable<boolean> = this.userSubject.pipe(map((user) => user !== null));
  readonly loading$: Observable<boolean> = this.loadingSubject.asObservable();
  readonly error$: Observable<string | null> = this.errorSubject.asObservable();
  readonly checked$: Observable<boolean> = this.checkedSubject.asObservable();

  constructor(private readonly api: AuthApiService) {}

  get currentUser(): AuthUser | null {
    return this.userSubject.value;
  }

  /**
   * Calls `GET /api/v1/auth/me` to restore login state after a page
   * refresh. Resolves to `null` (never throws) — an expected 401 for a
   * logged-out visitor is not an application error.
   */
  checkSession(): Observable<AuthUser | null> {
    this.loadingSubject.next(true);
    return this.api.me().pipe(
      tap((user) => {
        this.userSubject.next(user);
        this.errorSubject.next(null);
      }),
      catchError(() => {
        this.userSubject.next(null);
        return of(null);
      }),
      finalize(() => {
        this.loadingSubject.next(false);
        this.checkedSubject.next(true);
      }),
    );
  }

  signup(payload: SignupPayload): Observable<AuthUser> {
    this.errorSubject.next(null);
    return this.api.signup(payload).pipe(
      tap((user) => this.userSubject.next(user)),
      catchError((err) => {
        this.errorSubject.next(this.extractErrorMessage(err));
        throw err;
      }),
    );
  }

  login(payload: LoginPayload): Observable<AuthUser> {
    this.errorSubject.next(null);
    return this.api.login(payload).pipe(
      tap((user) => this.userSubject.next(user)),
      catchError((err) => {
        this.errorSubject.next(this.extractErrorMessage(err));
        throw err;
      }),
    );
  }

  logout(): Observable<void> {
    return this.api.logout().pipe(
      tap(() => this.userSubject.next(null)),
      catchError(() => {
        // Logout is idempotent server-side (tech-design.md §13.4) — even if
        // the request fails (e.g. network blip), the user's intent was to
        // log out, so clear local state anyway.
        this.userSubject.next(null);
        return of(undefined);
      }),
    );
  }

  /**
   * Called by the message store/API layer (CP18) when a 401 comes back on
   * an already-authenticated request (session expired/invalidated
   * server-side). Synchronously drops local auth state so the
   * state-driven conditional in `AppComponent` shows the login screen.
   */
  clearSession(): void {
    this.userSubject.next(null);
  }

  private extractErrorMessage(err: unknown): string {
    const httpError = err as { error?: { errors?: Record<string, string[]> } };
    const errors = httpError?.error?.errors;
    if (errors) {
      return Object.values(errors).flat().join(' ');
    }
    return 'Something went wrong. Please try again.';
  }
}
