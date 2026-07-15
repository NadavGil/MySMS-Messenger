import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { environment } from '../../environments/environment';
import { AuthUser } from '../models/auth.model';
import { AuthStoreService } from './auth-store.service';

describe('AuthStoreService', () => {
  let service: AuthStoreService;
  let httpMock: HttpTestingController;
  const baseUrl = `${environment.apiBaseUrl}/api/v1/auth`;

  const alice: AuthUser = { id: '664f1', username: 'alice' };

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [AuthStoreService],
    });
    service = TestBed.inject(AuthStoreService);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('starts logged out with checked=false', () => {
    expect(service.currentUser).toBeNull();
    const state: { checked: boolean } = { checked: true };
    service.checked$.subscribe((c) => (state.checked = c));
    expect(state.checked).toBe(false);
  });

  it('checkSession() publishes the user on a 200 and marks checked=true', () => {
    service.checkSession().subscribe();
    httpMock.expectOne(`${baseUrl}/me`).flush(alice);

    expect(service.currentUser).toEqual(alice);
    const state: { loggedIn: boolean; checked: boolean } = { loggedIn: false, checked: false };
    service.loggedIn$.subscribe((v) => (state.loggedIn = v));
    service.checked$.subscribe((c) => (state.checked = c));
    expect(state.loggedIn).toBe(true);
    expect(state.checked).toBe(true);
  });

  it('checkSession() resolves to null (not an error) on a 401', () => {
    let result: AuthUser | null | undefined;
    service.checkSession().subscribe((r) => (result = r));
    httpMock
      .expectOne(`${baseUrl}/me`)
      .flush({ errors: { base: ['Not authenticated'] } }, { status: 401, statusText: 'Unauthorized' });

    expect(result).toBeNull();
    expect(service.currentUser).toBeNull();
  });

  it('login() publishes the user on success', () => {
    service.login({ username: 'alice', password: 'hunter2secret' }).subscribe();
    httpMock.expectOne(`${baseUrl}/login`).flush(alice);

    expect(service.currentUser).toEqual(alice);
  });

  it('login() publishes an error message and rethrows on failure', () => {
    let threw = false;
    service.login({ username: 'alice', password: 'wrong' }).subscribe({
      error: () => (threw = true),
    });
    httpMock
      .expectOne(`${baseUrl}/login`)
      .flush(
        { errors: { base: ['Invalid username or password'] } },
        { status: 401, statusText: 'Unauthorized' },
      );

    expect(threw).toBe(true);
    const state: { error: string | null } = { error: null };
    service.error$.subscribe((e) => (state.error = e));
    expect(state.error).toBe('Invalid username or password');
    expect(service.currentUser).toBeNull();
  });

  it('signup() publishes the user on success', () => {
    service.signup({ username: 'alice', password: 'hunter2secret' }).subscribe();
    httpMock.expectOne(`${baseUrl}/signup`).flush(alice, { status: 201, statusText: 'Created' });

    expect(service.currentUser).toEqual(alice);
  });

  it('logout() clears the user and calls DELETE /api/v1/auth/logout', () => {
    service.login({ username: 'alice', password: 'hunter2secret' }).subscribe();
    httpMock.expectOne(`${baseUrl}/login`).flush(alice);
    expect(service.currentUser).toEqual(alice);

    service.logout().subscribe();
    httpMock.expectOne(`${baseUrl}/logout`).flush(null, { status: 204, statusText: 'No Content' });

    expect(service.currentUser).toBeNull();
  });

  it('clearSession() synchronously drops auth state (used for 401 handling on message calls, CP18)', () => {
    service.login({ username: 'alice', password: 'hunter2secret' }).subscribe();
    httpMock.expectOne(`${baseUrl}/login`).flush(alice);
    expect(service.currentUser).toEqual(alice);

    service.clearSession();

    expect(service.currentUser).toBeNull();
    const state: { loggedIn: boolean } = { loggedIn: true };
    service.loggedIn$.subscribe((v) => (state.loggedIn = v));
    expect(state.loggedIn).toBe(false);
  });
});
