import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { environment } from '../../environments/environment';
import { AuthUser } from '../models/auth.model';
import { AuthApiService } from './auth-api.service';

describe('AuthApiService', () => {
  let service: AuthApiService;
  let httpMock: HttpTestingController;
  const baseUrl = `${environment.apiBaseUrl}/api/v1/auth`;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [AuthApiService],
    });
    service = TestBed.inject(AuthApiService);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('signup() POSTs to /api/v1/auth/signup with withCredentials and the payload', () => {
    const payload = { username: 'alice', password: 'hunter2secret' };
    const mockResponse: AuthUser = { id: '664f1', username: 'alice' };

    service.signup(payload).subscribe((res) => {
      expect(res).toEqual(mockResponse);
    });

    const req = httpMock.expectOne(`${baseUrl}/signup`);
    expect(req.request.method).toBe('POST');
    expect(req.request.withCredentials).toBe(true);
    expect(req.request.body).toEqual(payload);
    req.flush(mockResponse, { status: 201, statusText: 'Created' });
  });

  it('login() POSTs to /api/v1/auth/login with withCredentials and the payload', () => {
    const payload = { username: 'alice', password: 'hunter2secret' };
    const mockResponse: AuthUser = { id: '664f1', username: 'alice' };

    service.login(payload).subscribe((res) => {
      expect(res).toEqual(mockResponse);
    });

    const req = httpMock.expectOne(`${baseUrl}/login`);
    expect(req.request.method).toBe('POST');
    expect(req.request.withCredentials).toBe(true);
    expect(req.request.body).toEqual(payload);
    req.flush(mockResponse);
  });

  it('login() surfaces a 401 with the generic "Invalid username or password" shape', () => {
    let capturedError: unknown;
    service.login({ username: 'alice', password: 'wrong' }).subscribe({
      error: (err) => (capturedError = err),
    });

    const req = httpMock.expectOne(`${baseUrl}/login`);
    req.flush(
      { errors: { base: ['Invalid username or password'] } },
      { status: 401, statusText: 'Unauthorized' },
    );

    expect((capturedError as { status: number }).status).toBe(401);
  });

  it('logout() DELETEs /api/v1/auth/logout with withCredentials', () => {
    service.logout().subscribe();

    const req = httpMock.expectOne(`${baseUrl}/logout`);
    expect(req.request.method).toBe('DELETE');
    expect(req.request.withCredentials).toBe(true);
    req.flush(null, { status: 204, statusText: 'No Content' });
  });

  it('me() GETs /api/v1/auth/me with withCredentials', () => {
    const mockResponse: AuthUser = { id: '664f1', username: 'alice' };

    service.me().subscribe((res) => {
      expect(res).toEqual(mockResponse);
    });

    const req = httpMock.expectOne(`${baseUrl}/me`);
    expect(req.request.method).toBe('GET');
    expect(req.request.withCredentials).toBe(true);
    req.flush(mockResponse);
  });

  it('me() surfaces a 401 when not authenticated', () => {
    let capturedError: unknown;
    service.me().subscribe({ error: (err) => (capturedError = err) });

    const req = httpMock.expectOne(`${baseUrl}/me`);
    req.flush(
      { errors: { base: ['Not authenticated'] } },
      { status: 401, statusText: 'Unauthorized' },
    );

    expect((capturedError as { status: number }).status).toBe(401);
  });
});
