import { CommonModule } from '@angular/common';
import { Component, OnInit } from '@angular/core';
import { Observable } from 'rxjs';
import { NewMessageComponent } from './components/new-message/new-message.component';
import { MessageHistoryComponent } from './components/message-history/message-history.component';
import { LoginComponent } from './components/login/login.component';
import { SignupComponent } from './components/signup/signup.component';
import { AuthUser } from './models/auth.model';
import { AuthStoreService } from './services/auth-store.service';

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

  constructor(private readonly authStore: AuthStoreService) {
    this.user$ = this.authStore.user$;
    this.loggedIn$ = this.authStore.loggedIn$;
    this.checked$ = this.authStore.checked$;
  }

  ngOnInit(): void {
    this.authStore.checkSession().subscribe();
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
