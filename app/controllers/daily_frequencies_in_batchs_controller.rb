class DailyFrequenciesInBatchsController < ApplicationController
  before_action :require_current_clasroom
  before_action :require_teacher
  #before_action :require_allocation_on_lessons_board
  before_action :set_number_of_classes, only: [:new, :create, :edit_multiple]
  before_action :require_allow_to_modify_prev_years, only: [:create, :destroy_multiple]
  before_action :require_valid_daily_frequency_classroom

  def new
    @daily_frequency = DailyFrequency.new.localized
    @daily_frequency.unity = current_unity
    @class_numbers = []
    @period = current_teacher_period

    authorize @daily_frequency
  end

  def create
    dates = [*params[:frequency_in_batch_form][:start_date].to_date..params[:frequency_in_batch_form][:end_date].to_date]

    invalid_dates = invalid_dates?(params[:frequency_in_batch_form][:start_date].to_date, params[:frequency_in_batch_form][:end_date].to_date)

    if invalid_dates
      flash[:error] = 'Datas inválidas'
      return redirect_to new_daily_frequencies_in_batch_path
    end

    allocated_dates = allocation_dates(dates)

    build_daily_frequencies_in_batch(allocated_dates)

    redirect_to edit_multiple_daily_frequencies_in_batchs_path(
                  frequency_in_batch_form: daily_frequency_in_batchs_params,
                  dates: allocated_dates
                )
  end

  def edit_multiple
    params[:dates].each do |date|
      @daily_frequencies = find_or_initialize_daily_frequencies(date[:date], date[:lesson_numbers])
    end
    @daily_frequency = @daily_frequencies.first
    teacher_period = current_teacher_period
    @period = teacher_period != Periods::FULL.to_i ? teacher_period : nil
    @general_configuration = GeneralConfiguration.current

    authorize @daily_frequency

    @students = []
    @any_exempted_from_discipline = false
    @any_inactive_student = false
    @any_in_active_search = false

    fetch_student_enrollments.each do |student_enrollment|
      student = Student.find_by(id: student_enrollment.student_id)

      next if student.blank?

      dependence = student_has_dependence?(student_enrollment, @daily_frequency.discipline)
      exempted_from_discipline = student_exempted_from_discipline?(student_enrollment, @daily_frequency)
      in_active_search = ActiveSearch.new.in_active_search?(student_enrollment.id, @daily_frequency.frequency_date)
      @any_exempted_from_discipline ||= exempted_from_discipline
      active = student_active_on_date?(student_enrollment)
      @any_in_active_search ||= in_active_search
      @any_inactive_student ||= !active

      @students << {
        student: student,
        dependence: dependence,
        active: active,
        exempted_from_discipline: exempted_from_discipline,
        in_active_search: in_active_search
      }
    end

    if @students.blank?
      flash.now[:warning] = t('.warning_no_students')

      render :new

      return
    end

    build_daily_frequency_students
    mark_for_destruction_not_existing_students

    @normal_students = @students.reject { |student| student[:dependence] }
    @dependence_students = @students.select { |student| student[:dependence] }

    Honeybadger.context(
      'Method': 'edit_multiple',
      'Turma da frequencia': @daily_frequency&.classroom_id,
      'Disciplina da frequencia': @daily_frequency&.discipline_id,
      'Turma do usuario atual': current_user&.current_classroom_id,
      'Disciplina do usuario atual': current_user&.current_discipline_id,
      'Professor do usuario atual': current_user&.teacher_id,
      'Tipo de frequencia': @daily_frequency&.classroom&.exam_rule&.frequency_type,
      'params': params
    )
  end

  def create_or_update_multiple
    begin
      daily_frequency_record = nil
      daily_frequency_attributes = daily_frequency_in_batchs_params
      daily_frequencies_attributes = daily_frequencies_in_batch_params
      receive_email_confirmation = ActiveRecord::Type::Boolean.new.type_cast_from_user(
        params[:frequency_in_batch_form][:receive_email_confirmation]
      )

      edit_multiple_daily_frequencies_path = edit_multiple_daily_frequencies_path(
        daily_frequency: daily_frequency_attributes.slice(
          :classroom_id,
          :discipline_id,
          :frequency_date,
          :period,
          :unity_id
        ),
        class_numbers: class_numbers_from_params
      )

      ActiveRecord::Base.transaction do
        daily_frequencies_attributes.each_value do |daily_frequency_students_params|
          daily_frequency_attribute_normalizer = DailyFrequencyAttributesNormalizer.new(
            daily_frequency_students_params,
            daily_frequency_attributes
          )
          daily_frequency_attribute_normalizer.normalize_daily_frequency!

          daily_frequency_record = find_or_initialize_daily_frequency_by(daily_frequency_attributes)
          daily_frequency_attribute_normalizer.normalize_daily_frequency_students!(
            daily_frequency_record,
            daily_frequency_students_params
          )
          daily_frequency_record.assign_attributes(daily_frequency_students_params)
          daily_frequency_record.save!
        end
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    flash[:success] = t('.daily_frequency_success')

    UniqueDailyFrequencyStudentsCreator.call_worker(
      current_entity.id,
      daily_frequency_record.classroom_id,
      daily_frequency_record.frequency_date,
      current_teacher_id
    )

    if receive_email_confirmation
      ReceiptMailer.delay.notify_daily_frequency_success(
        current_user,
        "#{request.base_url}#{edit_multiple_daily_frequencies_path}",
        daily_frequency_attributes[:frequency_date].to_date.strftime('%d/%m/%Y'),
        daily_frequency_record.classroom.description,
        daily_frequency_record.unity.name
      )
    end

    Honeybadger.context(
      'Method': 'create_or_update_multiple',
      'Turma da frequencia': daily_frequency_record&.classroom_id,
      'Disciplina da frequencia': daily_frequency_record&.discipline_id,
      'Numero de classes da frequencia': daily_frequency_record&.class_number,
      'Turma do usuario atual': current_user&.current_classroom_id,
      'Disciplina do usuario atual': current_user&.current_discipline_id,
      'Professor do usuario atual': current_user&.teacher_id,
      'Tipo de frequencia': daily_frequency_record&.classroom&.exam_rule&.frequency_type,
      'params': params
    )
  rescue StandardError => error
    Honeybadger.notify(error)

    flash[:alert] = t('.daily_frequency_error')
  ensure
    redirect_to edit_multiple_daily_frequencies_in_batchs_path
  end

  def destroy_multiple
    @daily_frequencies = DailyFrequency.where(id: params[:daily_frequencies_ids])

    if @daily_frequencies.any?
      daily_frequency = @daily_frequencies.first
      classroom_id = daily_frequency.classroom_id
      frequency_date = daily_frequency.frequency_date

      authorize daily_frequency

      @daily_frequencies.each(&:destroy)

      UniqueDailyFrequencyStudentsCreator.call_worker(
        current_entity.id,
        classroom_id,
        frequency_date,
        current_teacher_id
      )

      respond_with @daily_frequencies.first, location: new_daily_frequency_path
    else
      flash[:alert] = t('.alert')

      redirect_to new_daily_frequency_path
    end
  end

  def history
    @daily_frequency = DailyFrequency.find(params[:id])

    authorize @daily_frequency

    respond_with @daily_frequency
  end

  def history_multiple
    @daily_frequencies = DailyFrequency.where(id: params[:daily_frequencies_ids])

    respond_with @daily_frequencies
  end

  private

  def allocation_dates(dates)
    allocation_dates = []
    lesson_numbers = []
    dates.each do |date|
      allocations =  LessonsBoardLessonWeekday.by_classroom(params[:frequency_in_batch_form][:classroom_id])
                                              .by_teacher(current_teacher_id)
                                              .by_discipline(params[:frequency_in_batch_form][:discipline_id])
                                              .by_weekday(date.strftime("%A").downcase)
                                              .by_period(params[:frequency_in_batch_form][:period])

      if allocations.present?
        allocations.each { |allocattion| lesson_numbers << allocattion.lessons_board_lesson.lesson_number.to_i }
        allocation_dates << build_hash(date, lesson_numbers.uniq)
      end
    end

    allocation_dates
  end

  def build_hash(date, lesson_numbers)
    return if date.blank?

    {
      'date': date,
      'lesson_numbers': lesson_numbers
    }
  end

  def daily_frequency_in_batchs_params
    params.require(:frequency_in_batch_form).permit(
      :unity_id, :classroom_id, :discipline_id, :period, :start_date, :end_date
    )
  end

  def daily_frequencies_in_batch_params
    params.require(:frequency_in_batch_form).permit(
      daily_frequencies: [
        :class_number,
        students_attributes: [
          [:id, :daily_frequency_id, :student_id, :present, :dependence, :active, :type_of_teaching]
        ]
      ]
    ).require(:frequency_in_batch_form)
  end

  def current_frequency_type(daily_frequency)
    absence_type_definer = FrequencyTypeDefiner.new(
      daily_frequency.classroom,
      current_teacher,
      year: daily_frequency.classroom.year
    )
    absence_type_definer.define!

    absence_type_definer.frequency_type
  end

  def validate_class_numbers
    return true if @class_numbers.present?

    @error_on_class_numbers = true
    flash.now[:alert] = t('errors.daily_frequencies.class_numbers_required_when_not_global_absence')

    false
  end

  def validate_discipline
    return true if @discipline.present?

    @error_on_discipline = true
    flash.now[:alert] = t('errors.daily_frequencies.discipline_required_when_not_global_absence')

    false
  end

  def find_or_initialize_daily_frequencies(date, class_numbers)
    return find_or_initialize_discipline_frequencies(date, class_numbers) if class_numbers

    find_or_initialize_global_frequencies(date)
  end

  def find_or_initialize_global_frequencies(date)
    params = daily_frequency_in_batchs_params
    params[:discipline_id] = nil
    params[:class_number] = nil
    params[:frequency_date] = date

    [find_or_initialize_daily_frequency_by(params)]
  end

  def find_or_initialize_discipline_frequencies(date, class_numbers)
    daily_frequencies = []


    class_numbers.sort.each do |class_number|
      params = daily_frequency_in_batchs_params
      params[:frequency_date] = date
      params[:class_number] = class_number

      daily_frequencies << find_or_initialize_daily_frequency_by(params)
    end

    daily_frequencies
  end

  def find_or_initialize_daily_frequency_by(params)
    daily_frequency = DailyFrequency.find_or_initialize_by(
      params.slice(
        :classroom_id,
        :frequency_date,
        :discipline_id,
        :class_number,
        :period
      )
    ).tap do |daily_frequency_record|
      daily_frequency_record.unity_id = params[:unity_id]
      daily_frequency_record.school_calendar_id = current_school_calendar.id
      daily_frequency_record.owner_teacher_id = daily_frequency_record.teacher_id = current_teacher_id
      daily_frequency_record.origin = OriginTypes::WEB
    end

    @new_record ||= daily_frequency.new_record?

    daily_frequency
  end

  def current_teacher_period
    TeacherPeriodFetcher.new(
      current_teacher.id,
      current_user.current_classroom_id,
      current_user.current_discipline_id
    ).teacher_period
  end

  def build_daily_frequency_students
    @daily_frequencies.each do |daily_frequency|
      current_student_ids = daily_frequency.students.map(&:student_id)

      @students.each do |student|
        next if student[:exempted_from_discipline]
        next if current_student_ids.any? { |student_id| student_id == student[:student].id }

        daily_frequency.students.build(
          student_id: student[:student].id,
          dependence: student[:dependence],
          present: true,
          active: student[:active]
        )
      end
    end
  end

  def build_daily_frequencies_in_batch(dates)
    @daily_frequencies = []

    dates.each do |allocation_date|
      allocation_date[:lesson_numbers].each do |lesson_number|
        @daily_frequency = DailyFrequency.new(daily_frequency_in_batchs_params)
        @daily_frequency.school_calendar = current_school_calendar
        @daily_frequency.frequency_date = allocation_date[:date]
        @daily_frequency.teacher_id = current_teacher_id
        @daily_frequency.class_number = lesson_number
        @discipline = params[:frequency_in_batch_form][:discipline_id]
        @period = params[:frequency_in_batch_form][:period]

        if @daily_frequency.valid?
          frequency_type = current_frequency_type(@daily_frequency)

          return if frequency_type == FrequencyTypes::BY_DISCIPLINE && !(validate_discipline)
        else
          #todo pensar no que fazer quando algumas das frequencias forem inválidas
        end
        @daily_frequencies << @daily_frequency
      end
    end
    @daily_frequencies
  end

  def mark_for_destruction_not_existing_students
    current_student_ids = @students.map { |student| student[:student].id }

    @daily_frequencies.each do |daily_frequency|
      daily_frequency_students = daily_frequency.students.reject { |daily_frequency_student|
        current_student_ids.include?(daily_frequency_student.student_id)
      }

      daily_frequency_students.each(&:mark_for_destruction)
    end
  end

  def fetch_student_enrollments
    StudentEnrollmentsList.new(
      classroom: @daily_frequency.classroom,
      discipline: @daily_frequency.discipline,
      date: @daily_frequency.frequency_date,
      search_type: :by_date,
      period: @period
    ).student_enrollments
  end

  def student_active_on_date?(student_enrollment)
    StudentEnrollment.where(id: student_enrollment)
                     .by_classroom(@daily_frequency.classroom)
                     .by_date(@daily_frequency.frequency_date)
                     .any?
  end

  def set_number_of_classes
    @number_of_classes = current_school_calendar.number_of_classes
  end

  def require_teacher
    return if current_teacher.present?

    flash[:alert] = t('errors.daily_frequencies.require_teacher')
    redirect_to root_path
  end

  def student_has_dependence?(student_enrollment, discipline)
    StudentEnrollmentDependence.by_student_enrollment(student_enrollment)
                               .by_discipline(discipline)
                               .any?
  end

  def student_exempted_from_discipline?(student_enrollment, daily_frequency)
    return false if daily_frequency.discipline_id.blank?

    discipline_id = daily_frequency.discipline.id
    frequency_date = daily_frequency.frequency_date
    step_number = daily_frequency.school_calendar.step(frequency_date).try(:to_number)

    student_enrollment.exempted_disciplines
                      .by_discipline(discipline_id)
                      .by_step_number(step_number)
                      .any?
  end

  def require_valid_daily_frequency_classroom
    return unless params[:frequency_in_batch_form]
    return unless params[:frequency_in_batch_form][:classroom_id]
    return if current_user.current_classroom_id == params[:frequency_in_batch_form][:classroom_id].to_i

    redirect_to new_daily_frequency_path
  end

  def require_allocation_on_lessons_board
    LessonsBoard.by_teacher(current_teacher)
                .by_classroom(current_user_classroom)
                .by_discipline(current_user_discipline)
                .exists?
    flash[:alert] = t('errors.daily_frequencies.require_lessons_board')
    redirect_to root_path
  end

  def invalid_dates?(start_date, end_date)
    return false unless start_date || end_date

    true if start_date > Time.zone.today || end_date > Time.zone.today
  end
end
