import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { environment } from '../../../environments/environment';
import { SignupComponent } from './signup.component';

describe('SignupComponent', () => {
  let fixture: ComponentFixture<SignupComponent>;
  let component: SignupComponent;
  let httpMock: HttpTestingController;
  const signupUrl = `${environment.apiBaseUrl}/api/v1/auth/signup`;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [SignupComponent, HttpClientTestingModule],
    }).compileComponents();

    fixture = TestBed.createComponent(SignupComponent);
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

  it('rejects a password under 8 characters', () => {
    component.form.controls.username.setValue('alice');
    component.form.controls.password.setValue('short');
    expect(component.form.invalid).toBe(true);
  });

  it('rejects a username with invalid characters', () => {
    component.form.controls.username.setValue('al!ce');
    component.form.controls.password.setValue('hunter2secret');
    expect(component.form.invalid).toBe(true);
  });

  it('becomes valid with a proper username and password', () => {
    component.form.controls.username.setValue('alice');
    component.form.controls.password.setValue('hunter2secret');
    expect(component.form.valid).toBe(true);
  });

  it('does not submit while the form is invalid', () => {
    component.onSubmit();
    httpMock.expectNone(signupUrl);
  });

  it('POSTs to /api/v1/auth/signup on submit', () => {
    component.form.controls.username.setValue('alice');
    component.form.controls.password.setValue('hunter2secret');
    component.onSubmit();

    const req = httpMock.expectOne(signupUrl);
    expect(req.request.method).toBe('POST');
    expect(req.request.withCredentials).toBe(true);
    req.flush({ id: '1', username: 'alice' }, { status: 201, statusText: 'Created' });

    expect(component.submitting).toBe(false);
    expect(component.errorMessage).toBeNull();
  });

  it('shows an inline error message on a 422 (e.g. username already taken)', () => {
    component.form.controls.username.setValue('alice');
    component.form.controls.password.setValue('hunter2secret');
    component.onSubmit();

    const req = httpMock.expectOne(signupUrl);
    req.flush(
      { errors: { username: ['is already taken'] } },
      { status: 422, statusText: 'Unprocessable Entity' },
    );

    expect(component.errorMessage).toContain('is already taken');
    expect(component.submitting).toBe(false);
  });

  it('emits switchToLogin when the "Log in" link is clicked', () => {
    let emitted = false;
    component.switchToLogin.subscribe(() => (emitted = true));

    const link: HTMLAnchorElement = fixture.nativeElement.querySelector('.switch-link a');
    link.click();

    expect(emitted).toBe(true);
  });
});
