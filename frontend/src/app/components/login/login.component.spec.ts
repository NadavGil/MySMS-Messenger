import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { environment } from '../../../environments/environment';
import { LoginComponent } from './login.component';

describe('LoginComponent', () => {
  let fixture: ComponentFixture<LoginComponent>;
  let component: LoginComponent;
  let httpMock: HttpTestingController;
  const loginUrl = `${environment.apiBaseUrl}/api/v1/auth/login`;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [LoginComponent, HttpClientTestingModule],
    }).compileComponents();

    fixture = TestBed.createComponent(LoginComponent);
    component = fixture.componentInstance;
    httpMock = TestBed.inject(HttpTestingController);
    fixture.detectChanges();
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('creates the component', () => {
    expect(component).toBeTruthy();
  });

  it('starts with an invalid, empty form and Submit disabled', () => {
    expect(component.form.invalid).toBe(true);
    const submitButton: HTMLButtonElement = fixture.nativeElement.querySelector('.submit-button');
    expect(submitButton.disabled).toBe(true);
  });

  it('becomes valid once username and password are filled in', () => {
    component.form.controls.username.setValue('alice');
    component.form.controls.password.setValue('hunter2secret');
    expect(component.form.valid).toBe(true);
  });

  it('does not submit while the form is invalid', () => {
    component.onSubmit();
    httpMock.expectNone(loginUrl);
  });

  it('POSTs to /api/v1/auth/login on submit', () => {
    component.form.controls.username.setValue('alice');
    component.form.controls.password.setValue('hunter2secret');
    component.onSubmit();

    const req = httpMock.expectOne(loginUrl);
    expect(req.request.method).toBe('POST');
    expect(req.request.withCredentials).toBe(true);
    req.flush({ id: '1', username: 'alice' });

    expect(component.submitting).toBe(false);
    expect(component.errorMessage).toBeNull();
  });

  it('shows an inline error message on a 401', () => {
    component.form.controls.username.setValue('alice');
    component.form.controls.password.setValue('wrongpass');
    component.onSubmit();

    const req = httpMock.expectOne(loginUrl);
    req.flush(
      { errors: { base: ['Invalid username or password'] } },
      { status: 401, statusText: 'Unauthorized' },
    );

    expect(component.errorMessage).toContain('Invalid username or password');
    expect(component.submitting).toBe(false);
  });

  it('emits switchToSignup when the "Sign up" link is clicked', () => {
    let emitted = false;
    component.switchToSignup.subscribe(() => (emitted = true));

    const link: HTMLAnchorElement = fixture.nativeElement.querySelector('.switch-link a');
    link.click();

    expect(emitted).toBe(true);
  });
});
