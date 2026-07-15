import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { vi } from 'vitest';
import { environment } from '../../environments/environment';
import { environment as prodEnvironment } from '../../environments/environment.production';
import { environment as devEnvironment } from '../../environments/environment.development';
import { ListMessagesResponse, Message } from '../models/message.model';
import { AuthStoreService } from './auth-store.service';
import { MessagesApiService } from './messages-api.service';

describe('MessagesApiService', () => {
  let service: MessagesApiService;
  let httpMock: HttpTestingController;
  let authStore: AuthStoreService;
  const baseUrl = `${environment.apiBaseUrl}/api/v1/messages`;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [MessagesApiService, AuthStoreService],
    });
    service = TestBed.inject(MessagesApiService);
    httpMock = TestBed.inject(HttpTestingController);
    authStore = TestBed.inject(AuthStoreService);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('sendMessage() POSTs to /api/v1/messages with withCredentials and the payload', () => {
    const payload = { to_number: '+14155550123', body: 'Hello there' };
    const mockResponse: Message = {
      id: '1',
      to_number: payload.to_number,
      body: payload.body,
      status: 'sent',
      external_sid: 'FAKE-ab12cd34',
      created_at: '2020-05-17T11:18:45Z',
    };

    service.sendMessage(payload).subscribe((res) => {
      expect(res).toEqual(mockResponse);
    });

    const req = httpMock.expectOne(baseUrl);
    expect(req.request.method).toBe('POST');
    expect(req.request.withCredentials).toBe(true);
    expect(req.request.body).toEqual(payload);
    req.flush(mockResponse);
  });

  it('listMessages() GETs /api/v1/messages with withCredentials and maps the response', () => {
    const mockResponse: ListMessagesResponse = {
      count: 2,
      messages: [
        {
          id: '1',
          to_number: '+14155550123',
          body: 'first',
          status: 'sent',
          external_sid: 'FAKE-1',
          created_at: '2020-05-17T11:18:45Z',
        },
        {
          id: '2',
          to_number: '+14155550123',
          body: 'second',
          status: 'sent',
          external_sid: 'FAKE-2',
          created_at: '2020-05-16T09:02:11Z',
        },
      ],
    };

    service.listMessages().subscribe((res) => {
      expect(res).toEqual(mockResponse);
      expect(res.count).toBe(2);
    });

    const req = httpMock.expectOne(baseUrl);
    expect(req.request.method).toBe('GET');
    expect(req.request.withCredentials).toBe(true);
    req.flush(mockResponse);
  });

  describe('401 handling (CP18, tech-design.md §13.7/§13.8)', () => {
    it('sendMessage() clears the auth session on a 401 and still rethrows the error', () => {
      const clearSessionSpy = vi.spyOn(authStore, 'clearSession');
      let capturedError: unknown;

      service.sendMessage({ to_number: '+14155550123', body: 'hi' }).subscribe({
        error: (err) => (capturedError = err),
      });

      const req = httpMock.expectOne(baseUrl);
      req.flush(
        { errors: { base: ['Not authenticated'] } },
        { status: 401, statusText: 'Unauthorized' },
      );

      expect(clearSessionSpy).toHaveBeenCalledTimes(1);
      expect((capturedError as { status: number }).status).toBe(401);
    });

    it('listMessages() clears the auth session on a 401 and still rethrows the error', () => {
      const clearSessionSpy = vi.spyOn(authStore, 'clearSession');
      let capturedError: unknown;

      service.listMessages().subscribe({
        error: (err) => (capturedError = err),
      });

      const req = httpMock.expectOne(baseUrl);
      req.flush(
        { errors: { base: ['Not authenticated'] } },
        { status: 401, statusText: 'Unauthorized' },
      );

      expect(clearSessionSpy).toHaveBeenCalledTimes(1);
      expect((capturedError as { status: number }).status).toBe(401);
    });

    it('does NOT clear the auth session on a non-401 error (e.g. 422 validation)', () => {
      const clearSessionSpy = vi.spyOn(authStore, 'clearSession');

      service.sendMessage({ to_number: '+14155550123', body: 'hi' }).subscribe({
        error: () => {},
      });

      const req = httpMock.expectOne(baseUrl);
      req.flush(
        { errors: { body: ['must be 250 characters or fewer'] } },
        { status: 422, statusText: 'Unprocessable Entity' },
      );

      expect(clearSessionSpy).not.toHaveBeenCalled();
    });
  });

  describe('environment apiBaseUrl convention (regression test for QA report round1 M2)', () => {
    // Every environment file's `apiBaseUrl` must be an origin-or-empty value
    // ONLY, never a path that includes `/api` — otherwise the fixed
    // `/api/v1/messages` suffix appended in MessagesApiService would produce
    // a double `/api/api/v1/messages`, exactly as production previously did.
    const buildUrl = (apiBaseUrl: string) => `${apiBaseUrl}/api/v1/messages`;

    // Bug blitz (2026-07-15) finding: this assertion still hardcoded the
    // pre-Bonus-2 assumption that production is a same-origin deploy behind
    // a reverse proxy (empty apiBaseUrl). Bonus 2 deliberately moved to a
    // genuine two-service, cross-origin Render deploy
    // (environment.production.ts now points at the API's own absolute
    // https://...onrender.com origin — see that file's comments and
    // tech-design.md §14.5), so this test had been failing/stale ever since
    // without anyone noticing, since `ng test` wasn't re-run after that
    // config change landed. Updated to assert the real convention — a
    // non-empty absolute origin with no trailing slash and no embedded
    // `/api` segment — while still guarding against the actual M2 regression
    // (a double `/api/api/...`).
    it('does not double-prefix /api in the production environment', () => {
      const url = buildUrl(prodEnvironment.apiBaseUrl);
      expect(prodEnvironment.apiBaseUrl).toBe('https://mysms-messenger-server.onrender.com');
      expect(prodEnvironment.apiBaseUrl.endsWith('/')).toBe(false);
      expect(url).toBe('https://mysms-messenger-server.onrender.com/api/v1/messages');
      expect(url).not.toContain('/api/api');
    });

    it('does not double-prefix /api in the development environment', () => {
      const url = buildUrl(devEnvironment.apiBaseUrl);
      expect(url).toBe('http://localhost:3000/api/v1/messages');
      expect(url).not.toContain('/api/api');
    });
  });
});
