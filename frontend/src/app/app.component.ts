import { CommonModule } from '@angular/common';
import { Component, OnInit } from '@angular/core';
import { Observable } from 'rxjs';
import { NewMessageComponent } from './components/new-message/new-message.component';
import { MessageHistoryComponent } from './components/message-history/message-history.component';
import { LoginComponent } from './components/login/login.component';
import { SignupComponent } from './components/signup/signup.component';
import { AuthUser } from './models/auth.model';
import { AuthStoreService } from './services/auth-store.service';
import { MessagesStoreService } from './services/messages-store.service';

/**
 * Application shell.
 *
 * Lays out the "MY SMS MESSENGER" header and the two side-by-side panels
 * described in the wireframe: `NewMessageComponent` (CP9) and
 * `MessageHistoryComponent` (CP10), per tech-design.md §8.2/§8.4.
 *
 * CP17 (tech-design.md §13.8): the messenger UI now only renders when the
 * `AuthStoreService` reports a logged-in user; otherwise the Login/Signup
 * forms render instead. This is a plain state-driven `@if` conditional in
 * the template (a real Angular structural directive), not a Router-based
 * guard — a single-page shell like this doesn't need route-level guarding.
 * `checkSession()` runs once on init to restore login state after a page
 * refresh, since the identity now lives in an HttpOnly cookie the JS can't
 * read directly (tech-design.md §13.1/§13.3).
 */
@Component({
  selector: 'app-root',
  standalone: true,
  imports: [CommonModule, NewMessageComponent, MessageHistoryComponent, LoginComponent, SignupComponent],
  templateUrl: './app.component.html',
  styleUrl: './app.component.css',
})
export class AppComponent implements OnInit {
  protected readonly title = 'MY SMS MESSENGER';

  readonly user$: Observable<AuthUser | null>;
  readonly loggedIn$: Observable<boolean>;
  readonly checked$: Observable<boolean>;

  /** Which auth panel is showing when logged out. Login is the default. */
  showSignup = false;

  constructor(
    private readonly authStore: AuthStoreService,
    private readonly messagesStore: MessagesStoreService,
  ) {
    this.user$ = this.authStore.user$;
    this.loggedIn$ = this.authStore.loggedIn$;
    this.checked$ = this.authStore.checked$;
  }

  ngOnInit(): void {
    this.authStore.checkSession().subscribe();

    // Bug blitz (2026-07-15) finding: MessagesStoreService is
    // `providedIn: 'root'`, so it outlives any single user's session.
    // Nothing was clearing it on logout, so on a shared/kiosk machine the
    // NEXT user to log in would briefly see the PREVIOUS user's message
    // count in the <h2>Message History (N)</h2> header (that count isn't
    // gated behind loading$/error$ like the list itself) until their own
    // refresh() resolved and overwrote it. Reacting to loggedIn$ here
    // (rather than reaching into AuthStoreService) covers BOTH the
    // explicit onLogout() button AND the automatic 401 clearSession() path
    // (MessagesApiService.handleAuthExpiry) without creating a circular
    // dependency between AuthStoreService and MessagesStoreService (which
    // itself depends on MessagesApiService, which depends on
    // AuthStoreService).
    this.loggedIn$.subscribe((loggedIn) => {
      if (!loggedIn) {
        this.messagesStore.clear();
      }
    });
  }

  onLogout(): void {
    this.authStore.logout().subscribe();
  }

  onSwitchToSignup(): void {
    this.showSignup = true;
  }

  onSwitchToLogin(): void {
    this.showSignup = false;
  }
}
