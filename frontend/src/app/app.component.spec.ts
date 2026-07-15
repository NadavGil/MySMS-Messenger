import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { environment } from '../environments/environment';
import { AppComponent } from './app.component';

describe('AppComponent', () => {
  let httpMock: HttpTestingController;
  const meUrl = `${environment.apiBaseUrl}/api/v1/auth/me`;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [AppComponent, HttpClientTestingModule],
    }).compileComponents();
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('should create the app shell', () => {
    // No detectChanges() here (matches the original test) -> ngOnInit
    // hasn't run yet, so no /auth/me request is in flight; httpMock.verify()
    // in afterEach confirms that.
    const app = TestBed.createComponent(AppComponent).componentInstance;
    expect(app).toBeTruthy();
  });

  it('should render the "MY SMS MESSENGER" header', () => {
    const fixture = TestBed.createComponent(AppComponent);
    fixture.detectChanges();
    httpMock
      .expectOne(meUrl)
      .flush({ errors: { base: ['Not authenticated'] } }, { status: 401, statusText: 'Unauthorized' });
    const compiled = fixture.nativeElement as HTMLElement;
    expect(compiled.querySelector('h1')?.textContent).toContain('MY SMS MESSENGER');
  });

  it('should show the Login form when logged out (checkSession() 401s)', () => {
    const fixture = TestBed.createComponent(AppComponent);
    fixture.detectChanges();
    httpMock
      .expectOne(meUrl)
      .flush({ errors: { base: ['Not authenticated'] } }, { status: 401, statusText: 'Unauthorized' });
    fixture.detectChanges();
    const compiled = fixture.nativeElement as HTMLElement;
    expect(compiled.querySelector('app-login')).toBeTruthy();
    expect(compiled.querySelectorAll('.panel').length).toBe(0);
  });

  it('should render two side-by-side panels once logged in (checkSession() 200s)', () => {
    const fixture = TestBed.createComponent(AppComponent);
    fixture.detectChanges();
    httpMock.expectOne(meUrl).flush({ id: '1', username: 'alice' });
    fixture.detectChanges();
    const compiled = fixture.nativeElement as HTMLElement;
    const panels = compiled.querySelectorAll('.panel');
    expect(panels.length).toBe(2);
    expect(compiled.querySelector('.auth-username')?.textContent).toContain('alice');

    // Now-visible MessageHistoryComponent triggers its own initial
    // store.refresh() GET on init — flush it so httpMock.verify() is clean.
    const messagesUrl = `${environment.apiBaseUrl}/api/v1/messages`;
    httpMock.expectOne(messagesUrl).flush({ count: 0, messages: [] });
  });
});
